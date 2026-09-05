[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('init', 'start', 'supervise', 'status', 'history', 'stop', 'checkpoint', 'extend', 'repair-boundary', 'doctor')]
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
  [ValidateSet('deadline-aware', 'proof-first')]
  [string]$DeliveryMode = 'deadline-aware',
  [string]$DeadlineUtc = '',
  [int]$AdditionalBudgetMinutes = 0,
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
. (Join-Path $PSScriptRoot 'deadline_policy.ps1')

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
  $scratchDirectory = Join-Path $Root ".agent\deadline-carl-scratch\$Id"
  return [pscustomobject]@{
    RuntimeDirectory = $runtimeDirectory
    Config = Join-Path $runtimeDirectory 'config.json'
    Runtime = Join-Path $runtimeDirectory 'runtime.json'
    Logs = Join-Path $runtimeDirectory 'logs'
    SupervisorLog = Join-Path $runtimeDirectory 'logs\supervisor.log'
    TaskDirectory = Join-Path $Root ".agent\tasks\$Id"
    ScratchDirectory = $scratchDirectory
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

function Ensure-ConfigFields([object]$Config) {
  $defaults = [ordered]@{
    deliveryMode = 'deadline-aware'
    budgetExtensionSeconds = 0
    deadlineUtc = $null
  }
  foreach ($entry in $defaults.GetEnumerator()) {
    if ($null -eq $Config.PSObject.Properties[$entry.Key]) {
      $Config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
    }
  }
  if ([string]$Config.deliveryMode -notin @('deadline-aware', 'proof-first')) {
    throw "Unsupported deliveryMode in durable configuration: $($Config.deliveryMode)"
  }
  return $Config
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
    currentScratchDirectory = $null
    activeArtifactSnapshot = $null
    lastWriteBoundaryStatus = 'not-run'
    lastWriteBoundaryViolations = @()
    lastWriteBoundaryRecovery = $null
    writeBoundaryRecoveryHistory = @()
    lastHeartbeatUtc = $null
    lastTickUtc = $null
    lastCheckpointUtc = $null
    stopRequested = $false
    stopReason = $null
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
  Initialize-AdaptiveState $State
  $State.remainingActiveSeconds = [Math]::Max(
    0.0,
    [double]$Config.activeBudgetSeconds - [double]$State.accumulatedActiveSeconds
  )
  return $State
}

function Get-TaskArtifactSnapshot([string]$TaskDirectory) {
  $snapshot = [ordered]@{}
  if (-not (Test-Path -LiteralPath $TaskDirectory)) { return $snapshot }
  foreach ($file in @(Get-ChildItem -LiteralPath $TaskDirectory -File -Recurse -Force | Sort-Object FullName)) {
    $relativePath = $file.FullName.Substring($TaskDirectory.Length).TrimStart('\', '/').Replace('\', '/')
    try {
      $snapshot[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch {
      $snapshot[$relativePath] = '<unreadable>'
    }
  }
  return $snapshot
}

function Convert-SnapshotToMap([object]$Snapshot) {
  $map = @{}
  if ($null -eq $Snapshot) { return $map }
  if ($Snapshot -is [System.Collections.IDictionary]) {
    foreach ($key in $Snapshot.Keys) { $map[[string]$key] = [string]$Snapshot[$key] }
  } else {
    foreach ($property in $Snapshot.PSObject.Properties) {
      $map[[string]$property.Name] = [string]$property.Value
    }
  }
  return $map
}

function Test-PhaseArtifactWriteAllowed([string]$Phase, [string]$RelativePath) {
  $path = $RelativePath.Replace('\', '/').ToLowerInvariant()
  if ($path -eq 'deadline-report.md') { return $true }
  switch ($Phase) {
    'freeze' { return $path -eq 'spec.md' }
    'build' { return $path -eq 'progress.json' }
    'evidence' { return $path -in @('evidence.md', 'evidence.json') -or $path.StartsWith('raw/') }
    'verify' { return $path -in @('verdict.json', 'problems.md') }
    'fix' { return $path -in @('progress.json', 'evidence.md', 'evidence.json') -or $path.StartsWith('raw/') }
    default { return $false }
  }
}

function Get-PhaseAllowedTaskWrites([string]$Phase) {
  $allowed = [System.Collections.Generic.List[string]]::new()
  $allowed.Add('deadline-report.md')
  switch ($Phase) {
    'freeze' { $allowed.Add('spec.md') }
    'build' { $allowed.Add('progress.json') }
    'evidence' {
      $allowed.Add('evidence.md'); $allowed.Add('evidence.json'); $allowed.Add('raw/**')
    }
    'verify' { $allowed.Add('verdict.json'); $allowed.Add('problems.md') }
    'fix' {
      $allowed.Add('progress.json'); $allowed.Add('evidence.md'); $allowed.Add('evidence.json'); $allowed.Add('raw/**')
    }
    default { throw "Unknown phase: $Phase" }
  }
  return @($allowed)
}

function Test-SafeRelativeTaskPath([string]$RelativePath) {
  if (-not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':')) { return $false }
  $normalized = $RelativePath.Replace('\', '/')
  if ($normalized.StartsWith('/') -or $normalized.EndsWith('/')) { return $false }
  foreach ($segment in $normalized.Split('/')) {
    if (-not $segment -or $segment -in @('.', '..')) { return $false }
  }
  return $true
}

function Resolve-ContainedPath([string]$BasePath, [string]$RelativePath) {
  if (-not (Test-SafeRelativeTaskPath $RelativePath)) { return $null }
  $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $candidate = [IO.Path]::GetFullPath((Join-Path $baseFull $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
  $prefix = $baseFull + [IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
  return $candidate
}

function Test-PathChainHasReparsePoint([string]$Path, [string]$Boundary) {
  $current = [IO.Path]::GetFullPath($Path)
  $boundaryFull = [IO.Path]::GetFullPath($Boundary).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  while ($current.StartsWith($boundaryFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    }
    if ($current.Equals($boundaryFull, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = Split-Path -Parent $current
    if (-not $parent -or $parent -eq $current) { break }
    $current = $parent
  }
  return $false
}

function Get-CreatedBoundaryPaths([object[]]$Violations, [string]$Phase) {
  $paths = [System.Collections.Generic.List[string]]::new()
  if (@($Violations).Count -eq 0) { return @() }
  foreach ($violation in @($Violations)) {
    $text = [string]$violation
    if (-not $text.StartsWith('created:', [System.StringComparison]::Ordinal)) { return @() }
    $relativePath = $text.Substring('created:'.Length)
    if (-not (Test-SafeRelativeTaskPath $relativePath) -or (Test-PhaseArtifactWriteAllowed $Phase $relativePath)) { return @() }
    $paths.Add($relativePath.Replace('\', '/'))
  }
  return @($paths | Sort-Object -Unique)
}

function Invoke-BoundaryQuarantine(
  [object]$Config,
  [object]$Paths,
  [object]$State,
  [object[]]$Violations,
  [ValidateSet('automatic', 'repair-boundary')][string]$Mode
) {
  $relativePaths = @(Get-CreatedBoundaryPaths $Violations ([string]$State.phase))
  if ($relativePaths.Count -eq 0) {
    return [pscustomobject]@{ succeeded = $false; reason = 'Violations are not exclusively safe, disallowed created files.' }
  }

  if ((Test-PathChainHasReparsePoint $Paths.TaskDirectory $Config.repoRoot) -or
      (Test-PathChainHasReparsePoint $Paths.ScratchDirectory $Config.repoRoot)) {
    return [pscustomobject]@{ succeeded = $false; reason = 'Formal task or scratch ancestry contains a reparse point.' }
  }

  $scratchRoot = [IO.Path]::GetFullPath([string]$Paths.ScratchDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $parent = if ($Mode -eq 'automatic') { [string]$State.currentScratchDirectory } else { Join-Path $scratchRoot 'repairs' }
  if (-not $parent) {
    return [pscustomobject]@{ succeeded = $false; reason = 'No scratch directory is available for recovery.' }
  }
  $parentFull = [IO.Path]::GetFullPath($parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $scratchPrefix = $scratchRoot + [IO.Path]::DirectorySeparatorChar
  if (-not ($parentFull.Equals($scratchRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      $parentFull.StartsWith($scratchPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
    return [pscustomobject]@{ succeeded = $false; reason = 'Recovery destination escapes the configured scratch directory.' }
  }

  Ensure-Directory $parentFull
  if (Test-PathChainHasReparsePoint $parentFull $scratchRoot) {
    return [pscustomobject]@{ succeeded = $false; reason = 'Recovery destination contains a reparse point.' }
  }
  $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $recoveryDirectory = Join-Path $parentFull ("boundary-$Mode-$stamp-$([Guid]::NewGuid().ToString('N').Substring(0, 8))")
  Ensure-Directory $recoveryDirectory

  $moves = [System.Collections.Generic.List[object]]::new()
  foreach ($relativePath in $relativePaths) {
    $sourcePath = Resolve-ContainedPath $Paths.TaskDirectory $relativePath
    if (-not $sourcePath -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
      return [pscustomobject]@{ succeeded = $false; reason = "Created file is missing or unsafe: $relativePath" }
    }
    if (Test-PathChainHasReparsePoint $sourcePath $Paths.TaskDirectory) {
      return [pscustomobject]@{ succeeded = $false; reason = "Created file crosses a reparse point: $relativePath" }
    }
    $destinationPath = Resolve-ContainedPath $recoveryDirectory $relativePath
    if (-not $destinationPath -or (Test-Path -LiteralPath $destinationPath)) {
      return [pscustomobject]@{ succeeded = $false; reason = "Recovery destination is unsafe or already exists: $relativePath" }
    }
    $file = Get-Item -LiteralPath $sourcePath -Force
    $moves.Add([pscustomobject]@{
      relativePath = $relativePath
      sourcePath = $sourcePath
      destinationPath = $destinationPath
      sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
      sizeBytes = [long]$file.Length
    })
  }

  $moved = [System.Collections.Generic.List[object]]::new()
  try {
    foreach ($move in $moves) {
      Ensure-Directory (Split-Path -Parent $move.destinationPath)
      Move-Item -LiteralPath $move.sourcePath -Destination $move.destinationPath
      $moved.Add($move)
    }
    $manifestPath = Join-Path $recoveryDirectory 'manifest.json'
    $manifest = [pscustomobject]@{
      schemaVersion = 1
      mode = $Mode
      taskId = [string]$Config.taskId
      phase = [string]$State.phase
      iteration = $State.activeIteration
      quarantinedAtUtc = Get-UtcNowIso
      reason = 'Created file exceeded the phase-specific formal task write allowlist.'
      items = @($moves)
    }
    Write-JsonAtomic $manifestPath $manifest
    return [pscustomobject]@{
      succeeded = $true; mode = $Mode; manifestPath = $manifestPath
      recoveryDirectory = $recoveryDirectory; items = @($moves); atUtc = $manifest.quarantinedAtUtc
    }
  } catch {
    $rollbackMoves = @($moved)
    [array]::Reverse($rollbackMoves)
    foreach ($move in $rollbackMoves) {
      if ((Test-Path -LiteralPath $move.destinationPath -PathType Leaf) -and -not (Test-Path -LiteralPath $move.sourcePath)) {
        Ensure-Directory (Split-Path -Parent $move.sourcePath)
        Move-Item -LiteralPath $move.destinationPath -Destination $move.sourcePath -ErrorAction SilentlyContinue
      }
    }
    return [pscustomobject]@{ succeeded = $false; reason = "Recovery failed and moved files were rolled back: $($_.Exception.Message)" }
  }
}

function Test-PhaseWriteBoundary([string]$Phase, [object]$BeforeSnapshot, [string]$TaskDirectory) {
  if ($null -eq $BeforeSnapshot) {
    return [pscustomobject]@{ checked = $false; passed = $true; violations = @() }
  }
  $before = Convert-SnapshotToMap $BeforeSnapshot
  $after = Convert-SnapshotToMap (Get-TaskArtifactSnapshot $TaskDirectory)
  $allPaths = @($before.Keys) + @($after.Keys) | Sort-Object -Unique
  $violations = [System.Collections.Generic.List[string]]::new()
  foreach ($path in $allPaths) {
    $beforeHasPath = $before.ContainsKey($path)
    $afterHasPath = $after.ContainsKey($path)
    if ($beforeHasPath -and $afterHasPath -and $before[$path] -eq $after[$path]) { continue }
    if (Test-PhaseArtifactWriteAllowed $Phase $path) { continue }
    $change = if (-not $beforeHasPath) { 'created' } elseif (-not $afterHasPath) { 'deleted' } else { 'modified' }
    $violations.Add("${change}:$path")
  }
  return [pscustomobject]@{
    checked = $true
    passed = $violations.Count -eq 0
    violations = @($violations)
  }
}

function Get-DeadlineContext([object]$Config, [object]$State) {
  $totalSeconds = [Math]::Max(1, [int]$Config.activeBudgetSeconds)
  $remainingSeconds = [Math]::Max(0, [int]$State.remainingActiveSeconds)
  $remainingPercent = [Math]::Round(($remainingSeconds * 100.0) / $totalSeconds, 1)
  $remainingIterations = [Math]::Max(0, [int]$Config.maxIterations - [int]$State.iterationsStarted)
  $stage = 'proof-first'
  $guidance = 'Follow the frozen contract in proof-first order. The budget is a safety limit, not a reason to weaken verification.'

  if ($State.completed) {
    $stage = 'complete'
    $guidance = 'The proof package is complete. Do not start additional work unless the user creates a new scoped task.'
  } elseif ($State.blocked) {
    $stage = 'blocked'
    $guidance = 'The loop is blocked. Preserve state and resolve the recorded blocker before forcing a restart.'
  } elseif ([string]$Config.deliveryMode -eq 'deadline-aware') {
    $decision = Get-PlanningDecision $Config $State
    $stage = $decision.stage
    $guidance = $decision.reason
  }

  return [pscustomobject]@{
    deliveryMode = [string]$Config.deliveryMode
    stage = $stage
    totalMinutes = [Math]::Round($totalSeconds / 60.0, 1)
    remainingMinutes = [Math]::Round($remainingSeconds / 60.0, 1)
    remainingPercent = $remainingPercent
    iterationTimeoutMinutes = [Math]::Round(([int]$Config.iterationTimeoutSeconds) / 60.0, 1)
    remainingIterations = $remainingIterations
    guidance = $guidance
    effectiveRemainingMinutes = [Math]::Round((Get-EffectiveSeconds $Config $State) / 60.0, 2)
    deadlineUtc = $Config.deadlineUtc
    decision = Get-PlanningDecision $Config $State
  }
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
      [double]$Config.maxTickSeconds,
      [Math]::Max(0.0, ($now - $last).TotalSeconds)
    )
    $elapsed = [Math]::Min($elapsed, [Math]::Max(0.0, [double]$Config.activeBudgetSeconds - [double]$State.accumulatedActiveSeconds))
    $State.accumulatedActiveSeconds = [double]$State.accumulatedActiveSeconds + $elapsed
    # A tick can straddle phase/strategy boundaries. Allocate only actual overlap,
    # rather than charging the entire tick to the newest interval.
    $chargeStart = $now.AddSeconds(-$elapsed)
    $unassigned = $elapsed
    foreach ($interval in @($State.strategyHistory)) {
      $intervalStart = ConvertTo-DateTimeOffsetValue $interval.startedAtUtc
      $intervalEnd = if ($interval.endedAtUtc) { ConvertTo-DateTimeOffsetValue $interval.endedAtUtc } else { $now }
      $overlapStart = if ($intervalStart -gt $chargeStart) { $intervalStart } else { $chargeStart }
      $overlapEnd = if ($intervalEnd -lt $now) { $intervalEnd } else { $now }
      $credit = [Math]::Min($unassigned, [Math]::Max(0.0, ($overlapEnd - $overlapStart).TotalSeconds))
      $interval.activeSeconds += $credit
      $unassigned -= $credit
    }
    $State.historyBaselineActiveSeconds += $unassigned
  }
  $State.lastTickUtc = $now.ToString('o')
  $State.lastHeartbeatUtc = $now.ToString('o')
  $State.remainingActiveSeconds = [Math]::Max(
    0.0,
    [double]$Config.activeBudgetSeconds - [double]$State.accumulatedActiveSeconds
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
    $lastObserved = if ($State.lastHeartbeatUtc) { (ConvertTo-DateTimeOffsetValue $State.lastHeartbeatUtc).ToUniversalTime().ToString('o') } else { Get-UtcNowIso }
    Close-StrategyInterval $State $lastObserved 'supervisor-interrupted-last-observed'
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

function Invoke-ProofArtifactValidation([string]$Root, [string]$Id, [string]$Artifact) {
  $python = Get-PythonExecutable
  & $python $TaskHelper validate --task-id $Id --repo-root $Root --artifact $Artifact *> $null
  return $LASTEXITCODE -eq 0
}

function Invoke-ProofPlanSync([string]$Root, [string]$Id, [bool]$ForcePlan, [bool]$MigrateEvidence) {
  $python = Get-PythonExecutable
  $arguments = @($TaskHelper, 'sync-plan', '--task-id', $Id, '--repo-root', $Root)
  if ($ForcePlan) { $arguments += '--force' }
  if ($MigrateEvidence) { $arguments += '--migrate-evidence' }
  & $python @arguments *> $null
  return $LASTEXITCODE -eq 0
}

function Get-ProofStatus([string]$Root, [string]$Id) {
  try {
    $python = Get-PythonExecutable
    $output = & $python $TaskHelper status --task-id $Id --repo-root $Root 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($output | Out-String) | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Test-FrozenSpec([object]$Paths) {
  $path = Join-Path $Paths.TaskDirectory 'spec.md'
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
  $criterionPattern = '(?mi)^(?:\s*[-*+]\s+AC\d+\s*:|\s{0,3}#{2,6}\s+AC\d+(?:\s*[:—-]|\s*$))'
  $todoCriterionPattern = '(?mi)^(?:\s*[-*+]\s+AC\d+\s*:\s*|\s{0,3}#{2,6}\s+AC\d+(?:\s*[:—-]\s*|\s+))TODO\s*$'
  if ($content -match $todoCriterionPattern) { return $false }
  if ($content -match '(?ms)## Constraints\s+- TODO\s*(?:\r?\n|$)') { return $false }
  if ($content -match '(?ms)## Non-goals\s+- TODO\s*(?:\r?\n|$)') { return $false }
  return $content -match $criterionPattern
}

function Test-EvidenceReady([object]$Paths) {
  $config = Read-Json (Join-Path $Paths.RuntimeDirectory 'config.json')
  return Invoke-ProofArtifactValidation $config.repoRoot $config.taskId 'evidence'
}

function Test-WorkPlanReady([object]$Paths) {
  $config = Read-Json (Join-Path $Paths.RuntimeDirectory 'config.json')
  return Invoke-ProofArtifactValidation $config.repoRoot $config.taskId 'plan'
}

function Test-BuildReady([object]$Paths) {
  $config = Read-Json (Join-Path $Paths.RuntimeDirectory 'config.json')
  if (-not (Invoke-ProofArtifactValidation $config.repoRoot $config.taskId 'progress')) { return $false }
  $proofStatus = Get-ProofStatus $config.repoRoot $config.taskId
  if (-not $proofStatus -or -not $proofStatus.progress) { return $false }
  $total = [int]$proofStatus.progress.work_items_total
  return $total -gt 0 -and [int]$proofStatus.progress.implemented -eq $total -and [int]$proofStatus.progress.blocked -eq 0
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
    'freeze' { return (Test-FrozenSpec $Paths) -and (Test-WorkPlanReady $Paths) }
    'build' { return Test-BuildReady $Paths }
    'evidence' { return Test-EvidenceReady $Paths }
    'verify' {
      $config = Read-Json (Join-Path $Paths.RuntimeDirectory 'config.json')
      return (Invoke-ProofArtifactValidation $config.repoRoot $config.taskId 'verdict') -and $null -ne (Get-Verdict $Paths)
    }
    'fix' { return (Test-BuildReady $Paths) -and (Test-EvidenceReady $Paths) }
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

function New-IterationPrompt([object]$Config, [object]$State) {
  $template = Get-Content -LiteralPath $PromptTemplate -Raw -Encoding utf8
  $context = Get-DeadlineContext $Config $State
  $allowedTaskWrites = @(Get-PhaseAllowedTaskWrites ([string]$State.phase))
  $allowedTaskWritesJson = ConvertTo-Json $allowedTaskWrites -Compress
  $allowedTaskWritesMarkdown = ($allowedTaskWrites | ForEach-Object { "- ``$_``" }) -join "`r`n"
  $proofStatus = Get-ProofStatus $Config.repoRoot $Config.taskId
  $implementationProgress = if ($proofStatus -and $proofStatus.progress_display) { [string]$proofStatus.progress_display.implementation } else { '[unavailable]' }
  $verificationProgress = if ($proofStatus -and $proofStatus.progress_display) { [string]$proofStatus.progress_display.verification } else { '[unavailable]' }
  $acceptanceProgress = if ($proofStatus -and $proofStatus.progress_display) { [string]$proofStatus.progress_display.acceptance } else { '[unavailable]' }
  return $template.Replace('{{REPO_ROOT}}', [string]$Config.repoRoot).
    Replace('{{TASK_ID}}', [string]$Config.taskId).
    Replace('{{PHASE}}', [string]$State.phase).
    Replace('{{DELIVERY_MODE}}', [string]$context.deliveryMode).
    Replace('{{DEADLINE_STAGE}}', [string]$context.stage).
    Replace('{{ACTIVE_BUDGET_MINUTES}}', [string]$context.totalMinutes).
    Replace('{{REMAINING_ACTIVE_MINUTES}}', [string]$context.remainingMinutes).
    Replace('{{REMAINING_PERCENT}}', [string]$context.remainingPercent).
    Replace('{{ITERATION_TIMEOUT_MINUTES}}', [string]$context.iterationTimeoutMinutes).
    Replace('{{REMAINING_ITERATIONS}}', [string]$context.remainingIterations).
    Replace('{{DEADLINE_GUIDANCE}}', [string]$context.guidance).
    Replace('{{FORECAST_CONTEXT}}', ($context.decision | ConvertTo-Json -Depth 8 -Compress)).
    Replace('{{PREVIOUS_FORECAST}}', ($State.forecast | ConvertTo-Json -Depth 8 -Compress)).
    Replace('{{EFFECTIVE_REMAINING_MINUTES}}', [string]$context.effectiveRemainingMinutes).
    Replace('{{DEADLINE_UTC}}', [string]$context.deadlineUtc).
    Replace('{{TASK_HELPER}}', [string]$TaskHelper).
    Replace('{{SCRATCH_DIR}}', [string]$State.currentScratchDirectory).
    Replace('{{FORMAL_TASK_DIR}}', (Join-Path ([string]$Config.repoRoot) ".agent\tasks\$($Config.taskId)")).
    Replace('{{ALLOWED_TASK_WRITES_JSON}}', $allowedTaskWritesJson).
    Replace('{{ALLOWED_TASK_WRITES_MARKDOWN}}', $allowedTaskWritesMarkdown).
    Replace('{{IMPLEMENTATION_PROGRESS}}', $implementationProgress).
    Replace('{{VERIFICATION_PROGRESS}}', $verificationProgress).
    Replace('{{ACCEPTANCE_PROGRESS}}', $acceptanceProgress)
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
  $scratchPath = Join-Path $Paths.ScratchDirectory "iteration-$suffix"
  Ensure-Directory $Paths.Logs
  Ensure-Directory $scratchPath
  $State.currentScratchDirectory = $scratchPath
  $context = Get-DeadlineContext $Config $State
  $State.iterationStrategy = $context.stage
  if ($context.stage -in @('polish', 'craft', 'focus', 'ship', 'last-call') -and $State.selectedStrategy -ne $context.stage) {
    $State.selectedStrategy = $context.stage
    $State.promotionCandidate = ''; $State.promotionSamples = 0; $State.feasibleSamples = 0
  }
  $State.iterationForecast = $State.forecast
  $State.iterationStartActiveSeconds = $State.accumulatedActiveSeconds
  $State.iterationLimitSeconds = [int]$Config.iterationTimeoutSeconds
  if ($context.stage -eq 'polish') {
    $State.iterationLimitSeconds = [Math]::Min($State.iterationLimitSeconds, [Math]::Max(1, $context.decision.polishMinutes * 60))
  }
  $State.activeIteration = $iteration
  $State = Update-Elapsed $State $Config
  Open-StrategyInterval $State $context.stage $context.decision
  $State.activeArtifactSnapshot = Get-TaskArtifactSnapshot $Paths.TaskDirectory
  [System.IO.File]::WriteAllText(
    $promptPath,
    (New-IterationPrompt $Config $State),
    [System.Text.UTF8Encoding]::new($false)
  )
  # Record the opportunity as consumed only after generating its authorized prompt.
  if ($context.stage -eq 'polish') { $State.polishAttempts = @($State.polishAttempts) + @($State.forecast.polish.id) }

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

  $iterationEnvironment = [ordered]@{
    DEADLINE_CARL_TASK_ID = [string]$Config.taskId
    DEADLINE_CARL_PHASE = [string]$State.phase
    DEADLINE_CARL_ITERATION = [string]$iteration
    DEADLINE_CARL_OUTPUT_DIR = [string]$scratchPath
    DEADLINE_CARL_FORMAL_TASK_DIR = [string]$Paths.TaskDirectory
    DEADLINE_CARL_SCRATCH_DIR = [string]$scratchPath
    DEADLINE_CARL_ALLOWED_TASK_WRITES = ConvertTo-Json @(Get-PhaseAllowedTaskWrites ([string]$State.phase)) -Compress
  }
  $previousEnvironment = @{}
  $State = Update-Elapsed $State $Config
  if ((Get-EffectiveSeconds $Config $State) -le 0) { throw 'No effective time remains to launch another Worker.' }
  foreach ($entry in $iterationEnvironment.GetEnumerator()) {
    $previousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
  }
  try {
    $process = Start-Process `
      -FilePath $launcherPath `
      -ArgumentList ($launcherArguments -join ' ') `
      -WorkingDirectory $Config.repoRoot `
      -WindowStyle Hidden `
      -RedirectStandardInput $promptPath `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru
  } finally {
    foreach ($entry in $iterationEnvironment.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable($entry.Key, $previousEnvironment[$entry.Key], 'Process')
    }
  }
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
  $limit = if ($state.iterationLimitSeconds) { $state.iterationLimitSeconds } else { $Config.iterationTimeoutSeconds }
  $deadline = (ConvertTo-DateTimeOffsetValue $state.activeIterationStartedAtUtc).AddSeconds([double]$limit)
  $timedOut = $false

  while (Test-ProcessIdentity $state.activeChildPid $state.activeChildStartedAtUtc) {
    $waitSeconds = [Math]::Min([double]$Config.heartbeatSeconds, [Math]::Min((Get-EffectiveSeconds $Config $state), [Math]::Max(0, ($deadline - [DateTimeOffset]::UtcNow).TotalSeconds)))
    Start-Sleep -Milliseconds ([Math]::Max(1, [int]($waitSeconds * 1000)))
    $state = Read-State $Paths $Config
    $state = Update-Elapsed $state $Config
    if ((Get-EffectiveSeconds $Config $state) -le 0 -or [DateTimeOffset]::UtcNow -ge $deadline) {
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
  if ($timedOut) { return 124 }
  return $null
}

function Complete-Iteration([object]$Config, [object]$Paths, [object]$ExitCode) {
  $state = Read-State $Paths $Config
  $state = Update-Elapsed $state $Config
  $phase = [string]$state.phase
  $result = Read-IterationResult ([string]$state.currentSummaryPath)
  $validExit = $null -eq $ExitCode -or [int]$ExitCode -eq 0
  $validResult = $null -ne $result -and $result.phase -eq $phase
  $writeBoundary = Test-PhaseWriteBoundary $phase $state.activeArtifactSnapshot $Paths.TaskDirectory
  $originalBoundaryViolations = @($writeBoundary.violations)
  $boundaryRecovery = $null
  $boundaryRestored = $false
  if (-not $writeBoundary.passed -and @(Get-CreatedBoundaryPaths $writeBoundary.violations $phase).Count -gt 0) {
    $boundaryRecovery = Invoke-BoundaryQuarantine $Config $Paths $state $writeBoundary.violations 'automatic'
    if ($boundaryRecovery.succeeded) {
      $recheck = Test-PhaseWriteBoundary $phase $state.activeArtifactSnapshot $Paths.TaskDirectory
      $boundaryRestored = $recheck.passed
      if (-not $boundaryRestored) {
        $boundaryRecovery | Add-Member -NotePropertyName recheckViolations -NotePropertyValue @($recheck.violations)
      }
    }
  }
  $state.lastWriteBoundaryStatus = if (-not $writeBoundary.checked) { 'not-checked' } elseif ($writeBoundary.passed) { 'pass' } elseif ($boundaryRestored) { 'quarantined' } else { 'fail' }
  $state.lastWriteBoundaryViolations = $originalBoundaryViolations
  $state.lastWriteBoundaryRecovery = $boundaryRecovery
  if ($boundaryRecovery -and $boundaryRecovery.succeeded) {
    $state.writeBoundaryRecoveryHistory = @($state.writeBoundaryRecoveryHistory) + @($boundaryRecovery)
    Add-SupervisorLog $Paths "Created-only task files quarantined. phase=$phase manifest=$($boundaryRecovery.manifestPath) restored=$boundaryRestored"
  }
  if ($writeBoundary.passed -and $validExit -and $validResult -and $result.status -eq 'completed' -and $phase -eq 'freeze' -and (Test-FrozenSpec $Paths)) {
    Invoke-ProofPlanSync $Config.repoRoot $Config.taskId $true $true | Out-Null
  }
  $artifactsReady = Test-PhaseArtifacts $phase $Paths
  $state.currentIterationActive = $false
  $state.implementationReady = Test-BuildReady $Paths
  $state = Update-Elapsed $state $Config
  $forecastTrusted = $writeBoundary.passed -and $validExit -and $validResult -and $result.status -in @('progressed', 'completed')
  Receive-WorkForecast $state $Config $result.forecast $forecastTrusted
  $state.iterationHistory = @($state.iterationHistory) + @([pscustomobject]@{
    iteration = $state.activeIteration; phase = $phase; strategy = $state.iterationStrategy
    startedAtUtc = $state.activeIterationStartedAtUtc; endedAtUtc = Get-UtcNowIso
    activeSeconds = [Math]::Max(0, [double]$state.accumulatedActiveSeconds - [double]$state.iterationStartActiveSeconds)
    resultStatus = if ($validResult) { $result.status } else { 'invalid' }; exitCode = $ExitCode
    summary = if ($validResult) { $result.summary } else { 'No valid result returned.' }
    forecastBefore = $state.iterationForecast; forecastAfter = $state.forecast
    forecastStatus = $state.forecastStatus; writeBoundaryPassed = $writeBoundary.passed
    writeBoundaryStatus = $state.lastWriteBoundaryStatus; writeBoundaryViolations = $originalBoundaryViolations
    writeBoundaryRecovery = $boundaryRecovery
  })
  Close-StrategyInterval $state (Get-UtcNowIso) 'iteration-ended'
  Open-StrategyInterval $state 'waiting' ([pscustomobject]@{ reason = 'Supervisor transition, retry delay or process recovery; not worker execution.' })

  $state.lastIterationExitCode = $ExitCode
  $state.activeChildPid = $null
  $state.activeChildStartedAtUtc = $null
  $state.activeIterationStartedAtUtc = $null
  $state.currentIterationActive = $false
  $state.activeArtifactSnapshot = $null
  $state.lastCheckpointUtc = Get-UtcNowIso

  if ($validResult) {
    $state.lastIterationSummary = [string]$result.summary
  }

  if ($boundaryRestored) {
    $state.consecutiveFailures = [int]$state.consecutiveFailures + 1
    $state.lastIterationSummary = "Phase $phase created files outside its allowlist. They were quarantined for recovery; retrying the same phase: $($originalBoundaryViolations -join ', ')"
    $state.blockedReason = $null
  } elseif (-not $writeBoundary.passed) {
    $state.consecutiveFailures = [int]$state.consecutiveFailures + 1
    $state.blocked = $true
    $state.lastIterationSummary = "Phase $phase crossed its task-artifact write boundary: $(@($writeBoundary.violations) -join ', ')"
    $state.blockedReason = $state.lastIterationSummary
  } elseif ($validResult -and $result.status -eq 'blocked') {
    $state.blocked = $true
    $state.blockedReason = [string]$result.summary
  } elseif ($validExit -and $validResult -and $result.status -eq 'progressed') {
    $state.consecutiveFailures = 0
  } elseif ($validExit -and $validResult -and $result.status -eq 'completed' -and $artifactsReady) {
    $state.consecutiveFailures = 0
    $nextPhase = Get-NextPhase $phase $Paths
    if ($phase -eq 'build' -and $Config.deliveryMode -eq 'deadline-aware' -and
        (Get-PlanningDecision $Config $state).stage -eq 'polish') { $nextPhase = 'build' }
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

function Complete-Supervisor([object]$State, [object]$Paths, [object]$Config, [bool]$Completed) {
  $State = Update-Elapsed $State $Config
  $State.running = $false
  $State.supervisorPid = $null
  $State.supervisorStartedAtUtc = $null
  $State.lastTickUtc = $null
  $State.lastCheckpointUtc = Get-UtcNowIso
  if ($Completed) {
    $State.completed = $true
    $State.stopReason = 'completed'
    if (-not $State.completedAtUtc) { $State.completedAtUtc = Get-UtcNowIso }
  } elseif ($State.blocked) {
    $State.stopReason = 'blocked'
  } elseif ($State.stopRequested) {
    $State.stopReason = 'user-requested'
  } elseif ($State.remainingActiveSeconds -le 0) {
    $State.stopReason = 'active-budget-exhausted'
  } elseif ((Get-EffectiveSeconds $Config $State) -le 0) {
    $State.stopReason = 'absolute-deadline-reached'
  } elseif ([int]$State.iterationsStarted -ge [int]$Config.maxIterations) {
    $State.stopReason = 'max-iterations-exhausted'
  } else {
    $State.stopReason = 'stopped'
  }
  Close-StrategyInterval $State (Get-UtcNowIso) ([string]$State.stopReason)
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
  $deadline = Get-DeadlineContext $Config $State
  $proofStatus = Get-ProofStatus $Config.repoRoot $Config.taskId
  $timeUsedPercent = [Math]::Round(100.0 - [double]$deadline.remainingPercent, 1)
  $nonPassCriteria = @()
  if ($proofStatus -and $proofStatus.non_pass_criteria) {
    $nonPassCriteria = @($proofStatus.non_pass_criteria)
  }
  [pscustomobject]@{
    repoRoot = $Config.repoRoot
    taskId = $Config.taskId
    running = $State.running
    completed = $State.completed
    blocked = $State.blocked
    blockedReason = $State.blockedReason
    stopReason = $State.stopReason
    phase = $State.phase
    deliveryMode = $deadline.deliveryMode
    deadlineStage = $deadline.stage
    activeWorkerStrategy = if ($State.currentIterationActive) { $State.iterationStrategy } else { $null }
    planning = $deadline.decision
    forecast = $State.forecast
    effectiveRemainingMinutes = $deadline.effectiveRemainingMinutes
    deadlineUtc = $Config.deadlineUtc
    strategyHistory = @($State.strategyHistory | Select-Object -Last 10)
    iterationHistory = @($State.iterationHistory | Select-Object -Last 5)
    historyCounts = [pscustomobject]@{ intervals = @($State.strategyHistory).Count; iterations = @($State.iterationHistory).Count }
    budgetEvents = @($State.budgetEvents)
    budgetAssessment = Get-BudgetAssessment $State $Config
    activeBudgetSeconds = $Config.activeBudgetSeconds
    budgetExtensionSeconds = $Config.budgetExtensionSeconds
    remainingActivePercent = $deadline.remainingPercent
    activeTimeUsedPercent = $timeUsedPercent
    supervisorPid = $State.supervisorPid
    activeChildPid = $State.activeChildPid
    iterationsStarted = $State.iterationsStarted
    maxIterations = $Config.maxIterations
    iterationBudgetDisplay = "$($State.iterationsStarted)/$($Config.maxIterations)"
    accumulatedActiveSeconds = $State.accumulatedActiveSeconds
    remainingActiveSeconds = $State.remainingActiveSeconds
    lastHeartbeatUtc = $State.lastHeartbeatUtc
    lastCheckpointUtc = $State.lastCheckpointUtc
    lastIterationExitCode = $State.lastIterationExitCode
    lastIterationSummary = $State.lastIterationSummary
    consecutiveFailures = $State.consecutiveFailures
    proofInitialized = if ($proofStatus) { [bool]$proofStatus.exists } else { $false }
    proofInitInProgress = if ($proofStatus) { [bool]$proofStatus.init_in_progress } else { $false }
    evidenceOverallStatus = if ($proofStatus) { $proofStatus.evidence_overall_status } else { $null }
    verdictOverallStatus = if ($proofStatus) { $proofStatus.verdict_overall_status } else { $null }
    nonPassCriteria = $nonPassCriteria
    progressError = if ($proofStatus) { $proofStatus.progress_error } else { $null }
    progress = if ($proofStatus) { $proofStatus.progress } else { $null }
    progressDisplay = if ($proofStatus) { $proofStatus.progress_display } else { $null }
    gitHygiene = if ($proofStatus) { $proofStatus.git_hygiene } else { $null }
    taskDirectory = $Paths.TaskDirectory
    runtimeDirectory = $Paths.RuntimeDirectory
    scratchDirectory = $Paths.ScratchDirectory
    currentScratchDirectory = $State.currentScratchDirectory
    lastWriteBoundaryStatus = $State.lastWriteBoundaryStatus
    lastWriteBoundaryViolations = @($State.lastWriteBoundaryViolations)
    lastWriteBoundaryRecovery = $State.lastWriteBoundaryRecovery
    writeBoundaryRecoveryHistory = @($State.writeBoundaryRecoveryHistory | Select-Object -Last 10)
    supervisorLog = $Paths.SupervisorLog
  } | ConvertTo-Json -Depth 20
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
  if ($DeadlineUtc) {
    if ($DeadlineUtc -notmatch '(Z|[+-]\d{2}:\d{2})$') { throw 'DeadlineUtc requires an explicit timezone, for example 2026-09-05T18:00:00+08:00.' }
    $DeadlineUtc = (ConvertTo-DateTimeOffsetValue $DeadlineUtc).ToUniversalTime().ToString('o')
    if ((ConvertTo-DateTimeOffsetValue $DeadlineUtc) -le [DateTimeOffset]::UtcNow) { throw 'DeadlineUtc must be in the future.' }
  }
  Invoke-ProofInit $resolvedRepo $TaskId
  Ensure-Directory $paths.RuntimeDirectory
  Ensure-Directory $paths.Logs
  Ensure-Directory $paths.ScratchDirectory

  if (-not (Test-Path -LiteralPath $paths.Config)) {
    $config = [ordered]@{
      schemaVersion = 4
      taskId = $TaskId
      repoRoot = $resolvedRepo
      createdAtUtc = Get-UtcNowIso
      activeBudgetSeconds = $ActiveBudgetMinutes * 60
      budgetExtensionSeconds = 0
      iterationTimeoutSeconds = $IterationTimeoutMinutes * 60
      maxIterations = $MaxIterations
      heartbeatSeconds = $DefaultHeartbeatSeconds
      maxTickSeconds = $DefaultMaxTickSeconds
      retryDelaySeconds = [Math]::Max(1, $RetryDelaySeconds)
      cliUnavailableTimeoutSeconds = [Math]::Max(60, $CliUnavailableTimeoutMinutes * 60)
      maxConsecutiveFailures = [Math]::Max(1, $MaxConsecutiveFailures)
      deliveryMode = $DeliveryMode
      deadlineUtc = if ($DeadlineUtc) { $DeadlineUtc } else { $null }
      model = if ($Model) { $Model } else { $null }
      codexExecutable = if ($CodexExecutable) { (Resolve-Path -LiteralPath $CodexExecutable).Path } else { $null }
      approvalMode = 'approve-for-me'
    }
    Write-JsonAtomic $paths.Config $config
  }
  $config = Ensure-ConfigFields (Read-Json $paths.Config)

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
$config = Ensure-ConfigFields (Read-Json $paths.Config)
$state = Read-State $paths $config
if ($Command -ne 'supervise') {
  $state = Recover-StaleSupervisor $state $paths
}

switch ($Command) {
  'history' {
    [pscustomobject]@{
      taskId = $config.taskId; historyStartedAtUtc = $state.historyStartedAtUtc
      strategyHistory = @($state.strategyHistory); iterationHistory = @($state.iterationHistory)
      budgetEvents = @($state.budgetEvents); budgetAssessment = Get-BudgetAssessment $state $config
      writeBoundaryRecoveryHistory = @($state.writeBoundaryRecoveryHistory)
    } | ConvertTo-Json -Depth 20
  }
  'repair-boundary' {
    if ($state.running -or $state.currentIterationActive -or (Test-ProcessIdentity $state.activeChildPid $state.activeChildStartedAtUtc)) {
      throw 'Stop the loop and its active Worker before repairing a write-boundary violation.'
    }
    if (-not $state.blocked) { throw 'repair-boundary requires a blocked loop.' }
    if ($state.lastWriteBoundaryStatus -ne 'fail' -or @($state.lastWriteBoundaryViolations).Count -eq 0) {
      throw 'The blocked loop has no failed write-boundary record to repair.'
    }
    if (@(Get-CreatedBoundaryPaths $state.lastWriteBoundaryViolations ([string]$state.phase)).Count -eq 0) {
      throw 'repair-boundary only accepts violations composed entirely of safe created files; modified and deleted artifacts require manual review.'
    }
    $failuresBeforeRepair = [int]$state.consecutiveFailures
    $repair = Invoke-BoundaryQuarantine $config $paths $state $state.lastWriteBoundaryViolations 'repair-boundary'
    if (-not $repair.succeeded) { throw "Write-boundary repair refused: $($repair.reason)" }
    foreach ($item in @($repair.items)) {
      if (Test-Path -LiteralPath $item.sourcePath) {
        throw "Write-boundary repair did not remove the formal task file: $($item.relativePath)"
      }
    }
    $repair | Add-Member -NotePropertyName failuresBeforeRepair -NotePropertyValue $failuresBeforeRepair
    $state.lastWriteBoundaryStatus = 'repaired'
    $state.lastWriteBoundaryRecovery = $repair
    $state.writeBoundaryRecoveryHistory = @($state.writeBoundaryRecoveryHistory) + @($repair)
    $state.blocked = $false
    $state.blockedReason = $null
    $state.stopReason = 'boundary-repaired'
    $state.consecutiveFailures = 0
    $state.lastIterationSummary = "Created-only write-boundary violation repaired. Review quarantine manifest: $($repair.manifestPath)"
    $state.lastCheckpointUtc = Get-UtcNowIso
    Write-JsonAtomic $paths.Runtime $state
    Add-SupervisorLog $paths "Created-only write boundary repaired. manifest=$($repair.manifestPath)"
    Write-Status $config $paths $state
  }
  'status' {
    Write-Status $config $paths $state
  }
  'checkpoint' {
    $state.lastCheckpointUtc = Get-UtcNowIso
    Write-JsonAtomic $paths.Runtime $state
    Write-Status $config $paths $state
  }
  'extend' {
    if ($state.running) {
      throw 'Stop the loop before extending its active-time budget.'
    }
    if ($state.completed) {
      throw 'The loop is already complete; a completed task does not need more active-time budget.'
    }
    if ($AdditionalBudgetMinutes -le 0) {
      throw 'AdditionalBudgetMinutes must be positive.'
    }
    $additionalSeconds = $AdditionalBudgetMinutes * 60
    $config.activeBudgetSeconds = [int]$config.activeBudgetSeconds + $additionalSeconds
    $config.budgetExtensionSeconds = [int]$config.budgetExtensionSeconds + $additionalSeconds
    Write-JsonAtomic $paths.Config $config
    $state = Ensure-StateFields $state $config
    $state.stopReason = $null
    $state.budgetEvents = @($state.budgetEvents) + @([pscustomobject]@{
      atUtc = Get-UtcNowIso; type = 'active-budget-extension'; addedSeconds = $additionalSeconds
      totalSeconds = $config.activeBudgetSeconds; accumulatedActiveSeconds = $state.accumulatedActiveSeconds
    })
    $state.lastCheckpointUtc = Get-UtcNowIso
    Write-JsonAtomic $paths.Runtime $state
    Add-SupervisorLog $paths "Active-time budget extended by $AdditionalBudgetMinutes minutes. totalSeconds=$($config.activeBudgetSeconds)"
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
      if ($state.stopReason -ne 'completed') {
        $state.stopReason = 'completed'
        $state.lastCheckpointUtc = Get-UtcNowIso
        Write-JsonAtomic $paths.Runtime $state
      }
      Write-Status $config $paths $state
      exit 0
    }
    if ($state.blocked -and -not $Force) {
      throw "Loop is blocked: $($state.blockedReason). Resolve the blocker, then run start -Force."
    }
    if ($state.remainingActiveSeconds -le 0) { throw 'Active-time budget is exhausted. Stop the loop and use extend -AdditionalBudgetMinutes <minutes> to add an explicit recovery budget.' }
    if ((Get-EffectiveSeconds $config $state) -le 0) { throw 'Absolute deadline has passed; extending active time does not move it.' }
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
    $state.stopReason = $null
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
    $resumeStage = if ($state.currentIterationActive -and $state.iterationStrategy) { $state.iterationStrategy } else { 'waiting' }
    $resumeAt = (ConvertTo-DateTimeOffsetValue $state.lastTickUtc).ToUniversalTime().ToString('o')
    Open-StrategyInterval $state $resumeStage ([pscustomobject]@{ reason = 'Supervisor started or recovered; no stopped time is charged.' }) $resumeAt
    Write-JsonAtomic $paths.Runtime $state

    while ($true) {
      $state = Read-State $paths $config
      $state = Update-Elapsed $state $config
      Write-JsonAtomic $paths.Runtime $state

      if ($state.completed) {
        Complete-Supervisor $state $paths $config $true
        break
      }
      if ($state.blocked -or $state.stopRequested -or (Get-EffectiveSeconds $config $state) -le 0 -or
          (-not $state.currentIterationActive -and [int]$state.iterationsStarted -ge [int]$config.maxIterations)) {
        if ((Get-EffectiveSeconds $config $state) -le 0 -and (Test-ProcessIdentity $state.activeChildPid $state.activeChildStartedAtUtc)) {
          Stop-ProcessTree ([int]$state.activeChildPid)
          $state = Complete-Iteration $config $paths 124
        }
        Complete-Supervisor $state $paths $config $false
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
        Start-Sleep -Milliseconds ([Math]::Max(1, [int]([Math]::Min([double]$config.retryDelaySeconds, (Get-EffectiveSeconds $config $state)) * 1000)))
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

      if (-not $state.completed -and -not $state.blocked -and -not $state.stopRequested -and (Get-EffectiveSeconds $config $state) -gt 0) {
        Start-Sleep -Milliseconds ([Math]::Max(1, [int]([Math]::Min([double]$config.retryDelaySeconds, (Get-EffectiveSeconds $config $state)) * 1000)))
      }
    }
  }
}
