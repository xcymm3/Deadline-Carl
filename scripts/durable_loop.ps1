[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('init', 'start', 'supervise', 'status', 'stop', 'checkpoint', 'doctor')]
  [string]$Command = 'status',
  [string]$RepoRoot = (Get-Location).Path,
  [string]$TaskId = '',
  [string]$TaskText = '',
  [string]$TaskFile = '',
  [int]$ActiveBudgetMinutes = 720,
  [int]$IterationTimeoutMinutes = 25,
  [int]$MaxIterations = 30,
  [int]$RetryDelaySeconds = 20,
  [int]$CliUnavailableTimeoutMinutes = 30,
  [int]$MaxConsecutiveFailures = 6,
  [string]$Model = '',
  [string]$CodexExecutable = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
$TaskHelper = Join-Path $PSScriptRoot 'task_loop.py'
$PromptTemplate = Join-Path $SkillRoot 'assets\templates\durable-agent-prompt.md.tmpl'
$ResultSchema = Join-Path $SkillRoot 'assets\schemas\durable-iteration-result.schema.json'
$DefaultHeartbeatSeconds = 10
$DefaultMaxTickSeconds = 30

function ConvertTo-IsoUtc([datetime]$Value) {
  return $Value.ToUniversalTime().ToString('o')
}

function Get-UtcNowIso {
  return [DateTimeOffset]::UtcNow.ToString('o')
}

function ConvertTo-DateTimeOffsetValue([object]$Value) {
  if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
  if ($Value -is [datetime]) { return [DateTimeOffset]([datetime]$Value) }
  return [DateTimeOffset]::Parse(
    [string]$Value,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind
  )
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Read-Json([string]$Path) {
  return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Write-JsonAtomic([string]$Path, [object]$Value) {
  Ensure-Directory (Split-Path -Parent $Path)
  $tempPath = "$Path.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
  $json = $Value | ConvertTo-Json -Depth 30
  [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Resolve-RepositoryRoot([string]$Path) {
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  $gitOutput = @(& git -C $resolved rev-parse --show-toplevel 2>$null)
  $gitExitCode = $LASTEXITCODE
  $root = $gitOutput | Select-Object -First 1
  if ($gitExitCode -ne 0 -or -not $root) {
    throw "Not a Git repository: $resolved"
  }
  return (Resolve-Path -LiteralPath $root.Trim()).Path
}

function Assert-TaskId([string]$Value) {
  if (-not $Value -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
    throw 'TaskId must start with a letter or digit and contain only letters, digits, dot, underscore, or hyphen.'
  }
}

function Get-LoopPaths([string]$Root, [string]$Id) {
  $runtimeDirectory = Join-Path $Root ".agent\durable-loop\$Id"
  return [pscustomobject]@{
    RuntimeDirectory = $runtimeDirectory
    Config = Join-Path $runtimeDirectory 'config.json'
    Runtime = Join-Path $runtimeDirectory 'runtime.json'
    Logs = Join-Path $runtimeDirectory 'logs'
    SupervisorLog = Join-Path $runtimeDirectory 'logs\supervisor.log'
    TaskDirectory = Join-Path $Root ".agent\tasks\$Id"
  }
}

function Add-SupervisorLog([object]$Paths, [string]$Message) {
  Ensure-Directory $Paths.Logs
  Add-Content -LiteralPath $Paths.SupervisorLog -Encoding utf8 -Value "$(Get-Date -Format o) $Message"
}

function Get-ProcessStartUtc([int]$ProcessId) {
  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    return ConvertTo-IsoUtc $process.StartTime
  } catch {
    return $null
  }
}

function Test-ProcessIdentity([object]$ProcessId, [object]$StartedAtUtc) {
  if ($null -eq $ProcessId -or [int]$ProcessId -le 0) { return $false }
  try {
    $process = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop
    if (-not $StartedAtUtc) { return $true }
    $expected = (ConvertTo-DateTimeOffsetValue $StartedAtUtc).UtcDateTime
    $actual = $process.StartTime.ToUniversalTime()
    return [Math]::Abs(($actual - $expected).TotalSeconds) -lt 2
  } catch {
    return $false
  }
}

function Stop-ProcessTree([int]$ProcessId) {
  try {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction Stop)
    foreach ($child in $children) {
      Stop-ProcessTree ([int]$child.ProcessId)
    }
  } catch {
    # Fall back to stopping only the known process when CIM is unavailable.
  }
  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Ensure-StateFields([object]$State, [object]$Config) {
  $defaults = [ordered]@{
    running = $false
    completed = $false
    completedAtUtc = $null
    blocked = $false
    blockedReason = $null
    phase = 'freeze'
    iterationsStarted = 0
    accumulatedActiveSeconds = 0
    remainingActiveSeconds = [int]$Config.activeBudgetSeconds
    supervisorPid = $null
    supervisorStartedAtUtc = $null
    activeChildPid = $null
    activeChildStartedAtUtc = $null
    activeIteration = $null
    activeIterationStartedAtUtc = $null
    currentIterationActive = $false
    currentPromptPath = $null
    currentStdoutPath = $null
    currentStderrPath = $null
    currentSummaryPath = $null
    lastHeartbeatUtc = $null
    lastTickUtc = $null
    lastCheckpointUtc = $null
    stopRequested = $false
    lastIterationExitCode = $null
    lastIterationSummary = $null
    consecutiveFailures = 0
    cliUnavailableSinceUtc = $null
  }
  foreach ($entry in $defaults.GetEnumerator()) {
    if ($null -eq $State.PSObject.Properties[$entry.Key]) {
      $State | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
    }
  }
  $State.remainingActiveSeconds = [Math]::Max(
    0,
    [int]$Config.activeBudgetSeconds - [int]$State.accumulatedActiveSeconds
  )
  return $State
}

function Read-State([object]$Paths, [object]$Config) {
  if (-not (Test-Path -LiteralPath $Paths.Runtime)) {
    throw "Missing runtime state: $($Paths.Runtime). Run init first."
  }
  return Ensure-StateFields (Read-Json $Paths.Runtime) $Config
}

function Update-Elapsed([object]$State, [object]$Config) {
  $now = [DateTimeOffset]::UtcNow
  if ($State.lastTickUtc) {
    $last = ConvertTo-DateTimeOffsetValue $State.lastTickUtc
    $elapsed = [Math]::Min(
      [int]$Config.maxTickSeconds,
      [Math]::Max(0, [int]($now - $last).TotalSeconds)
    )
    $State.accumulatedActiveSeconds = [int]$State.accumulatedActiveSeconds + $elapsed
  }
  $State.lastTickUtc = $now.ToString('o')
  $State.lastHeartbeatUtc = $now.ToString('o')
  $State.remainingActiveSeconds = [Math]::Max(
    0,
    [int]$Config.activeBudgetSeconds - [int]$State.accumulatedActiveSeconds
  )
  return $State
}

function Recover-StaleSupervisor([object]$State, [object]$Paths) {
  if ($State.running -and -not (Test-ProcessIdentity $State.supervisorPid $State.supervisorStartedAtUtc)) {
    $oldPid = $State.supervisorPid
    $State.running = $false
    $State.supervisorPid = $null
    $State.supervisorStartedAtUtc = $null
    $State.lastTickUtc = $null
    $State.lastCheckpointUtc = Get-UtcNowIso
    Write-JsonAtomic $Paths.Runtime $State
    Add-SupervisorLog $Paths "Recovered stale supervisor. oldPid=$oldPid activeChildPid=$($State.activeChildPid)"
  }
  return $State
}

function Get-PythonExecutable {
  foreach ($name in @('python', 'python3')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
  }
  throw 'Python 3.10 or newer is required.'
}

function Get-CodexExecutable([object]$Config) {
  if ($Config.codexExecutable -and (Test-Path -LiteralPath ([string]$Config.codexExecutable))) {
    return (Resolve-Path -LiteralPath ([string]$Config.codexExecutable)).Path
  }
  $command = Get-Command codex -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  return $null
}

function Get-PowerShellExecutable {
  foreach ($name in @('pwsh', 'powershell')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
  }
  throw 'PowerShell is required.'
}

function Quote-ProcessArgument([string]$Value) {
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-ProofInit([string]$Root, [string]$Id) {
  $python = Get-PythonExecutable
  $arguments = @(
    $TaskHelper,
    'init',
    '--task-id', $Id,
    '--repo-root', $Root,
    '--guides', 'agents',
    '--install-subagents', 'codex'
  )
  if ($TaskFile) {
    $arguments += @('--task-file', (Resolve-Path -LiteralPath $TaskFile).Path)
  } elseif ($TaskText) {
    $arguments += @('--task-text', $TaskText)
  }
  $output = & $python @arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Proof-loop initialization failed with exit code $LASTEXITCODE. $($output | Out-String)"
  }
}

function Invoke-ProofValidation([string]$Root, [string]$Id) {
  $python = Get-PythonExecutable
  & $python $TaskHelper validate --task-id $Id --repo-root $Root *> $null
  return $LASTEXITCODE -eq 0
}

function Test-FrozenSpec([object]$Paths) {
  $path = Join-Path $Paths.TaskDirectory 'spec.md'
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
  if ($content -match '(?m)^- AC\d+:\s*TODO\s*$') { return $false }
  if ($content -match '(?ms)## Constraints\s+- TODO\s*(?:\r?\n|$)') { return $false }
  if ($content -match '(?ms)## Non-goals\s+- TODO\s*(?:\r?\n|$)') { return $false }
  return $content -match '(?m)^- AC\d+:'
}

function Test-EvidenceReady([object]$Paths) {
  $path = Join-Path $Paths.TaskDirectory 'evidence.json'
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  try {
    $evidence = Read-Json $path
    $criteria = @($evidence.acceptance_criteria)
    if ($criteria.Count -eq 0) { return $false }
    foreach ($criterion in $criteria) {
      if (-not $criterion.id -or -not $criterion.text -or $criterion.text -eq 'TODO') { return $false }
      if ($criterion.status -notin @('PASS', 'FAIL', 'UNKNOWN')) { return $false }
      if ($criterion.status -eq 'PASS' -and @($criterion.proof).Count -eq 0) { return $false }
    }
    return $true
  } catch {
    return $false
  }
}

function Get-Verdict([object]$Paths) {
  $path = Join-Path $Paths.TaskDirectory 'verdict.json'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $verdict = Read-Json $path
    if ($verdict.overall_verdict -notin @('PASS', 'FAIL', 'UNKNOWN')) { return $null }
    return [string]$verdict.overall_verdict
  } catch {
    return $null
  }
}

function Test-PhaseArtifacts([string]$Phase, [object]$Paths) {
  switch ($Phase) {
    'freeze' { return Test-FrozenSpec $Paths }
    'build' { return Test-FrozenSpec $Paths }
    'evidence' { return Test-EvidenceReady $Paths }
    'verify' { return $null -ne (Get-Verdict $Paths) }
    'fix' { return Test-EvidenceReady $Paths }
    default { return $false }
  }
}

function Get-NextPhase([string]$Phase, [object]$Paths) {
  switch ($Phase) {
    'freeze' { return 'build' }
    'build' { return 'evidence' }
    'evidence' { return 'verify' }
    'verify' {
      if ((Get-Verdict $Paths) -eq 'PASS') { return 'complete' }
      return 'fix'
    }
    'fix' { return 'verify' }
    default { throw "Unknown phase: $Phase" }
  }
}

function New-IterationPrompt([string]$Root, [string]$Id, [string]$Phase) {
  $template = Get-Content -LiteralPath $PromptTemplate -Raw -Encoding utf8
  return $template.Replace('{{REPO_ROOT}}', $Root).Replace('{{TASK_ID}}', $Id).Replace('{{PHASE}}', $Phase)
}

function Read-IterationResult([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $content = (Get-Content -LiteralPath $Path -Raw -Encoding utf8).Trim()
    if ($content.StartsWith('```')) {
      $content = $content -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
    }
    return $content | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Start-CodexIteration(
  [object]$State,
  [object]$Config,
  [object]$Paths,
  [string]$CodexPath
) {
  $iteration = [int]$State.iterationsStarted + 1
  $suffix = '{0:D3}-{1}' -f $iteration, $State.phase
  $promptPath = Join-Path $Paths.Logs "iteration-$suffix.prompt.md"
  $stdoutPath = Join-Path $Paths.Logs "iteration-$suffix.jsonl"
  $stderrPath = Join-Path $Paths.Logs "iteration-$suffix.stderr.log"
  $summaryPath = Join-Path $Paths.Logs "iteration-$suffix.final.json"
  Ensure-Directory $Paths.Logs
  [System.IO.File]::WriteAllText(
    $promptPath,
    (New-IterationPrompt $Config.repoRoot $Config.taskId $State.phase),
    [System.Text.UTF8Encoding]::new($false)
  )

  $arguments = @(
    'exec',
    '--cd', (Quote-ProcessArgument $Config.repoRoot),
    '--approve-for-me',
    '--json',
    '--color', 'never',
    '--output-schema', (Quote-ProcessArgument $ResultSchema),
    '--output-last-message', (Quote-ProcessArgument $summaryPath),
    '-'
  )
  if ($Config.model) {
    $arguments = @('exec', '--model', (Quote-ProcessArgument ([string]$Config.model))) + $arguments[1..($arguments.Count - 1)]
  }

  $launcherPath = $CodexPath
  $launcherArguments = $arguments
  if ([System.IO.Path]::GetExtension($CodexPath) -eq '.ps1') {
    $launcherPath = Get-PowerShellExecutable
    $launcherArguments = @(
      '-NoLogo',
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', (Quote-ProcessArgument $CodexPath)
    ) + $arguments
  }

  $process = Start-Process `
    -FilePath $launcherPath `
    -ArgumentList ($launcherArguments -join ' ') `
    -WorkingDirectory $Config.repoRoot `
    -WindowStyle Hidden `
    -RedirectStandardInput $promptPath `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru
  $null = $process.Handle

  $State.iterationsStarted = $iteration
  $State.currentIterationActive = $true
  $State.activeChildPid = $process.Id
  $State.activeChildStartedAtUtc = Get-ProcessStartUtc $process.Id
  $State.activeIteration = $iteration
  $State.activeIterationStartedAtUtc = Get-UtcNowIso
  $State.currentPromptPath = $promptPath
  $State.currentStdoutPath = $stdoutPath
  $State.currentStderrPath = $stderrPath
  $State.currentSummaryPath = $summaryPath
  $State.lastTickUtc = Get-UtcNowIso
  Write-JsonAtomic $Paths.Runtime $State
  Add-SupervisorLog $Paths "Iteration started. iteration=$iteration phase=$($State.phase) childPid=$($process.Id) codex=$CodexPath"
  return $process
}

function Wait-ForIteration(
  [object]$Config,
  [object]$Paths,
  [object]$OwnedProcess
) {
  $state = Read-State $Paths $Config
  $deadline = (ConvertTo-DateTimeOffsetValue $state.activeIterationStartedAtUtc).AddSeconds([int]$Config.iterationTimeoutSeconds)
  $timedOut = $false

  while (Test-ProcessIdentity $state.activeChildPid $state.activeChildStartedAtUtc) {
    Start-Sleep -Seconds ([int]$Config.heartbeatSeconds)
    $state = Read-State $Paths $Config
    $state = Update-Elapsed $state $Config
    if ($state.remainingActiveSeconds -le 0 -or [DateTimeOffset]::UtcNow -ge $deadline) {
      $timedOut = $true
      Stop-ProcessTree ([int]$state.activeChildPid)
      Add-SupervisorLog $Paths "Iteration terminated at timeout or budget limit. iteration=$($state.activeIteration)"
    }
    Write-JsonAtomic $Paths.Runtime $state
  }

  if ($OwnedProcess) {
    try {
      $OwnedProcess.WaitForExit()
      if ($timedOut) { return 124 }
      return $OwnedProcess.ExitCode
    } catch {
      return $(if ($timedOut) { 124 } else { 1 })
    }
  }
  Start-Sleep -Milliseconds 250
  return $null
}

function Complete-Iteration([object]$Config, [object]$Paths, [object]$ExitCode) {
  $state = Read-State $Paths $Config
  $phase = [string]$state.phase
  $result = Read-IterationResult ([string]$state.currentSummaryPath)
  $validExit = $null -eq $ExitCode -or [int]$ExitCode -eq 0
  $validResult = $null -ne $result -and $result.phase -eq $phase
  $artifactsReady = Test-PhaseArtifacts $phase $Paths

  $state.lastIterationExitCode = $ExitCode
  $state.activeChildPid = $null
  $state.activeChildStartedAtUtc = $null
  $state.activeIterationStartedAtUtc = $null
  $state.currentIterationActive = $false
  $state.lastCheckpointUtc = Get-UtcNowIso

  if ($validResult) {
    $state.lastIterationSummary = [string]$result.summary
  }

  if ($validResult -and $result.status -eq 'blocked') {
    $state.blocked = $true
    $state.blockedReason = [string]$result.summary
  } elseif ($validExit -and $validResult -and $result.status -eq 'completed' -and $artifactsReady) {
    $state.consecutiveFailures = 0
    $nextPhase = Get-NextPhase $phase $Paths
    if ($nextPhase -eq 'complete') {
      if ((Get-Verdict $Paths) -eq 'PASS' -and (Invoke-ProofValidation $Config.repoRoot $Config.taskId)) {
        $state.completed = $true
        $state.completedAtUtc = Get-UtcNowIso
      } else {
        $state.consecutiveFailures = 1
        $state.lastIterationSummary = 'Verifier reported PASS, but proof artifact validation failed.'
      }
    } else {
      $state.phase = $nextPhase
    }
  } else {
    $state.consecutiveFailures = [int]$state.consecutiveFailures + 1
    if (-not $validResult) {
      $state.lastIterationSummary = 'Codex did not return a valid structured iteration result.'
    } elseif (-not $artifactsReady) {
      $state.lastIterationSummary = "Phase $phase returned completed without ready proof artifacts."
    }
  }

  if ([int]$state.consecutiveFailures -ge [int]$Config.maxConsecutiveFailures) {
    $state.blocked = $true
    $state.blockedReason = "Stopped after $($state.consecutiveFailures) consecutive failures in phase $phase."
  }

  Write-JsonAtomic $Paths.Runtime $state
  Add-SupervisorLog $Paths "Iteration ended. iteration=$($state.activeIteration) phase=$phase exit=$ExitCode status=$($result.status) next=$($state.phase) completed=$($state.completed) failures=$($state.consecutiveFailures)"
  return $state
}

function Complete-Supervisor([object]$State, [object]$Paths, [bool]$Completed) {
  $State.running = $false
  $State.supervisorPid = $null
  $State.supervisorStartedAtUtc = $null
  $State.lastTickUtc = $null
  $State.lastCheckpointUtc = Get-UtcNowIso
  if ($Completed) {
    $State.completed = $true
    if (-not $State.completedAtUtc) { $State.completedAtUtc = Get-UtcNowIso }
  }
  Write-JsonAtomic $Paths.Runtime $State
  Add-SupervisorLog $Paths "Supervisor stopped. completed=$Completed blocked=$($State.blocked) remaining=$($State.remainingActiveSeconds)"
}

function Record-SupervisorFailure([object]$Config, [object]$Paths, [string]$Message) {
  $state = Read-State $Paths $Config
  $state.consecutiveFailures = [int]$state.consecutiveFailures + 1
  $state.lastIterationSummary = $Message
  $state.lastCheckpointUtc = Get-UtcNowIso
  if ([int]$state.consecutiveFailures -ge [int]$Config.maxConsecutiveFailures) {
    $state.blocked = $true
    $state.blockedReason = $Message
  }
  Write-JsonAtomic $Paths.Runtime $state
  Add-SupervisorLog $Paths "Supervisor failure. message=$Message failures=$($state.consecutiveFailures)"
  return $state
}

function Write-Status([object]$Config, [object]$Paths, [object]$State) {
  [pscustomobject]@{
    repoRoot = $Config.repoRoot
    taskId = $Config.taskId
    running = $State.running
    completed = $State.completed
    blocked = $State.blocked
    blockedReason = $State.blockedReason
    phase = $State.phase
    supervisorPid = $State.supervisorPid
    activeChildPid = $State.activeChildPid
    iterationsStarted = $State.iterationsStarted
    maxIterations = $Config.maxIterations
    accumulatedActiveSeconds = $State.accumulatedActiveSeconds
    remainingActiveSeconds = $State.remainingActiveSeconds
    lastHeartbeatUtc = $State.lastHeartbeatUtc
    lastCheckpointUtc = $State.lastCheckpointUtc
    lastIterationExitCode = $State.lastIterationExitCode
    lastIterationSummary = $State.lastIterationSummary
    consecutiveFailures = $State.consecutiveFailures
    taskDirectory = $Paths.TaskDirectory
    runtimeDirectory = $Paths.RuntimeDirectory
    supervisorLog = $Paths.SupervisorLog
  } | ConvertTo-Json -Depth 8
}

$resolvedRepo = Resolve-RepositoryRoot $RepoRoot

if ($Command -eq 'doctor') {
  $pythonPath = $null
  $pythonVersion = $null
  try {
    $pythonPath = Get-PythonExecutable
    $pythonVersion = (& $pythonPath --version 2>&1 | Out-String).Trim()
  } catch {}
  $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
  $loginStatus = $null
  $authenticated = $false
  if ($codexCommand) {
    $loginStatus = (& $codexCommand.Source login status 2>&1 | Out-String).Trim()
    $authenticated = $LASTEXITCODE -eq 0
  }
  [pscustomobject]@{
    skillRoot = $SkillRoot
    repoRoot = $resolvedRepo
    gitRepository = $true
    pythonPath = $pythonPath
    pythonVersion = $pythonVersion
    codexPath = if ($codexCommand) { $codexCommand.Source } else { $null }
    codexAuthenticated = $authenticated
    authenticationStatus = $loginStatus
    promptTemplateExists = Test-Path -LiteralPath $PromptTemplate
    resultSchemaExists = Test-Path -LiteralPath $ResultSchema
    taskHelperExists = Test-Path -LiteralPath $TaskHelper
    ready = $pythonPath -and $codexCommand -and $authenticated -and (Test-Path -LiteralPath $PromptTemplate) -and (Test-Path -LiteralPath $ResultSchema) -and (Test-Path -LiteralPath $TaskHelper)
  } | ConvertTo-Json -Depth 6
  exit 0
}

Assert-TaskId $TaskId
$paths = Get-LoopPaths $resolvedRepo $TaskId

if ($Command -eq 'init') {
  if ($ActiveBudgetMinutes -le 0 -or $IterationTimeoutMinutes -le 0 -or $MaxIterations -le 0) {
    throw 'Budget, iteration timeout, and max iterations must be positive.'
  }
  Invoke-ProofInit $resolvedRepo $TaskId
  Ensure-Directory $paths.RuntimeDirectory
  Ensure-Directory $paths.Logs

  if (-not (Test-Path -LiteralPath $paths.Config)) {
    $config = [ordered]@{
      schemaVersion = 1
      taskId = $TaskId
      repoRoot = $resolvedRepo
      createdAtUtc = Get-UtcNowIso
      activeBudgetSeconds = $ActiveBudgetMinutes * 60
      iterationTimeoutSeconds = $IterationTimeoutMinutes * 60
      maxIterations = $MaxIterations
      heartbeatSeconds = $DefaultHeartbeatSeconds
      maxTickSeconds = $DefaultMaxTickSeconds
      retryDelaySeconds = [Math]::Max(1, $RetryDelaySeconds)
      cliUnavailableTimeoutSeconds = [Math]::Max(60, $CliUnavailableTimeoutMinutes * 60)
      maxConsecutiveFailures = [Math]::Max(1, $MaxConsecutiveFailures)
      model = if ($Model) { $Model } else { $null }
      codexExecutable = if ($CodexExecutable) { (Resolve-Path -LiteralPath $CodexExecutable).Path } else { $null }
      approvalMode = 'approve-for-me'
    }
    Write-JsonAtomic $paths.Config $config
  }
  $config = Read-Json $paths.Config

  if (-not (Test-Path -LiteralPath $paths.Runtime)) {
    $state = [pscustomobject]@{}
    $state = Ensure-StateFields $state $config
    $state.lastCheckpointUtc = Get-UtcNowIso
    Write-JsonAtomic $paths.Runtime $state
  }
  $state = Read-State $paths $config
  Write-Status $config $paths $state
  exit 0
}

if (-not (Test-Path -LiteralPath $paths.Config)) {
  throw "Missing durable-loop configuration: $($paths.Config). Run init first."
}
$config = Read-Json $paths.Config
$state = Read-State $paths $config
if ($Command -ne 'supervise') {
  $state = Recover-StaleSupervisor $state $paths
}

switch ($Command) {
  'status' {
    Write-Status $config $paths $state
  }
  'checkpoint' {
    $state.lastCheckpointUtc = Get-UtcNowIso
    Write-JsonAtomic $paths.Runtime $state
    Write-Status $config $paths $state
  }
  'stop' {
    if (-not $state.running) {
      Write-Status $config $paths $state
      exit 0
    }
    $state.stopRequested = $true
    $state.lastCheckpointUtc = Get-UtcNowIso
    Write-JsonAtomic $paths.Runtime $state
    Add-SupervisorLog $paths 'Safe stop requested. The active iteration may finish; no new iteration will start.'
    Write-Status $config $paths $state
  }
  'start' {
    if ($state.running -and (Test-ProcessIdentity $state.supervisorPid $state.supervisorStartedAtUtc)) {
      Write-Status $config $paths $state
      exit 0
    }
    if ($state.completed) {
      Write-Status $config $paths $state
      exit 0
    }
    if ($state.blocked -and -not $Force) {
      throw "Loop is blocked: $($state.blockedReason). Resolve the blocker, then run start -Force."
    }
    if ($state.remainingActiveSeconds -le 0) { throw 'Active-time budget is exhausted.' }
    if ([int]$state.iterationsStarted -ge [int]$config.maxIterations) { throw 'Maximum iteration count is exhausted.' }

    if ($Force) {
      $state.blocked = $false
      $state.blockedReason = $null
      $state.consecutiveFailures = 0
    }
    $powershellPath = Get-PowerShellExecutable
    $arguments = @(
      '-NoLogo',
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', (Quote-ProcessArgument $PSCommandPath),
      'supervise',
      '-RepoRoot', (Quote-ProcessArgument $resolvedRepo),
      '-TaskId', (Quote-ProcessArgument $TaskId)
    )
    $hostStdout = Join-Path $paths.Logs 'supervisor-host.stdout.log'
    $hostStderr = Join-Path $paths.Logs 'supervisor-host.stderr.log'
    $process = Start-Process `
      -FilePath $powershellPath `
      -ArgumentList ($arguments -join ' ') `
      -WorkingDirectory $resolvedRepo `
      -WindowStyle Hidden `
      -RedirectStandardOutput $hostStdout `
      -RedirectStandardError $hostStderr `
      -PassThru
    $state.running = $true
    $state.supervisorPid = $process.Id
    $state.supervisorStartedAtUtc = Get-ProcessStartUtc $process.Id
    $state.stopRequested = $false
    $state.lastTickUtc = Get-UtcNowIso
    $state.lastHeartbeatUtc = Get-UtcNowIso
    $state.lastCheckpointUtc = Get-UtcNowIso
    Write-JsonAtomic $paths.Runtime $state
    Add-SupervisorLog $paths "Supervisor launched. pid=$($process.Id)"
    Write-Status $config $paths $state
  }
  'supervise' {
    Start-Sleep -Milliseconds 750
    $state = Read-State $paths $config
    if (-not $state.running -or [int]$state.supervisorPid -ne $PID) {
      Add-SupervisorLog $paths "Supervisor PID mismatch. expected=$($state.supervisorPid) actual=$PID"
      exit 2
    }
    Add-SupervisorLog $paths "Supervisor loop entered. pid=$PID phase=$($state.phase)"

    while ($true) {
      $state = Read-State $paths $config
      $state = Update-Elapsed $state $config
      Write-JsonAtomic $paths.Runtime $state

      if ($state.completed) {
        Complete-Supervisor $state $paths $true
        break
      }
      if ($state.blocked -or $state.stopRequested -or $state.remainingActiveSeconds -le 0 -or [int]$state.iterationsStarted -ge [int]$config.maxIterations) {
        Complete-Supervisor $state $paths $false
        break
      }

      if ($state.currentIterationActive) {
        $ownedProcess = $null
        if (Test-ProcessIdentity $state.activeChildPid $state.activeChildStartedAtUtc) {
          Add-SupervisorLog $paths "Adopting active iteration. iteration=$($state.activeIteration) childPid=$($state.activeChildPid)"
          $exitCode = Wait-ForIteration $config $paths $ownedProcess
        } else {
          $exitCode = $null
        }
        $state = Complete-Iteration $config $paths $exitCode
        continue
      }

      $codexPath = Get-CodexExecutable $config
      if (-not $codexPath) {
        if (-not $state.cliUnavailableSinceUtc) {
          $state.cliUnavailableSinceUtc = Get-UtcNowIso
          Add-SupervisorLog $paths 'Codex CLI is unavailable. Waiting for installation or desktop update to finish.'
        }
        $unavailableFor = ([DateTimeOffset]::UtcNow - (ConvertTo-DateTimeOffsetValue $state.cliUnavailableSinceUtc)).TotalSeconds
        if ($unavailableFor -ge [int]$config.cliUnavailableTimeoutSeconds) {
          $state.blocked = $true
          $state.blockedReason = 'Codex CLI remained unavailable beyond the configured recovery window.'
          Write-JsonAtomic $paths.Runtime $state
          continue
        }
        Write-JsonAtomic $paths.Runtime $state
        Start-Sleep -Seconds ([int]$config.retryDelaySeconds)
        continue
      }

      if ($state.cliUnavailableSinceUtc) {
        Add-SupervisorLog $paths "Codex CLI became available again. path=$codexPath"
        $state.cliUnavailableSinceUtc = $null
        Write-JsonAtomic $paths.Runtime $state
      }

      try {
        $process = Start-CodexIteration $state $config $paths $codexPath
        $exitCode = Wait-ForIteration $config $paths $process
        $state = Complete-Iteration $config $paths $exitCode
      } catch {
        $state = Record-SupervisorFailure $config $paths $_.Exception.Message
      }

      if (-not $state.completed -and -not $state.blocked -and -not $state.stopRequested) {
        Start-Sleep -Seconds ([int]$config.retryDelaySeconds)
      }
    }
  }
}
