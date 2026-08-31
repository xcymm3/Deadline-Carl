[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
$LoopScript = Join-Path $PSScriptRoot 'durable_loop.ps1'
$InstallScript = Join-Path $PSScriptRoot 'install_skill.ps1'
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase "codex-durable-loop-test-$([Guid]::NewGuid().ToString('N'))"
$repo = Join-Path $testRoot 'repo'
$taskId = 'recovery-test'
$statePath = Join-Path $repo ".agent\durable-loop\$taskId\runtime.json"
$delayMarker = Join-Path $repo ".agent\durable-loop\$taskId\delay-build-once"
$fakeCodex = Join-Path $testRoot 'fake-codex.ps1'
$startedSupervisors = [System.Collections.Generic.List[int]]::new()

function Read-TestState {
  if (-not (Test-Path -LiteralPath $statePath)) { return $null }
  return Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$FailureMessage) {
  $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
  while ([DateTimeOffset]::Now -lt $deadline) {
    if (& $Condition) { return }
    Start-Sleep -Milliseconds 250
  }
  throw $FailureMessage
}

function Stop-TestProcesses {
  $state = Read-TestState
  if ($state) {
    foreach ($processId in @($state.activeChildPid, $state.supervisorPid)) {
      if ($processId) { Stop-Process -Id ([int]$processId) -Force -ErrorAction SilentlyContinue }
    }
  }
  foreach ($processId in $startedSupervisors) {
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
  }
}

try {
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  & git -C $repo init *> $null
  & git -C $repo config user.email 'durable-loop-test@example.invalid'
  & git -C $repo config user.name 'Durable Loop Test'

  $fakeSource = @'
$ErrorActionPreference = 'Stop'
$allArguments = @($args)

function Get-ArgumentValue([string]$Name) {
  for ($index = 0; $index -lt $allArguments.Count - 1; $index++) {
    if ($allArguments[$index] -eq $Name) { return [string]$allArguments[$index + 1] }
  }
  return ''
}

$prompt = [Console]::In.ReadToEnd()
$root = Get-ArgumentValue '--cd'
$output = Get-ArgumentValue '--output-last-message'
$taskMatch = [regex]::Match($prompt, 'Task ID: `([^`]+)`')
$phaseMatch = [regex]::Match($prompt, 'Current phase: `([^`]+)`')
if (-not $taskMatch.Success -or -not $phaseMatch.Success -or -not $root -or -not $output) { exit 2 }

$task = $taskMatch.Groups[1].Value
$phase = $phaseMatch.Groups[1].Value
$taskDirectory = Join-Path $root ".agent\tasks\$task"
$runtimeDirectory = Join-Path $root ".agent\durable-loop\$task"
$marker = Join-Path $runtimeDirectory 'delay-build-once'

if ($phase -eq 'build' -and (Test-Path -LiteralPath $marker)) {
  Remove-Item -LiteralPath $marker
  Start-Sleep -Seconds 5
}

switch ($phase) {
  'freeze' {
    @"
# Task Spec: $task

## Original task statement
Create a proof file.

## Acceptance criteria
- AC1: product.txt exists and contains PASS.

## Constraints
- Preserve existing work.

## Non-goals
- No unrelated edits.

## Verification plan
- Check product.txt.
"@ | Set-Content -LiteralPath (Join-Path $taskDirectory 'spec.md') -Encoding utf8
  }
  'build' {
    'PASS' | Set-Content -LiteralPath (Join-Path $root 'product.txt') -Encoding utf8
  }
  { $_ -in @('evidence', 'fix') } {
    [ordered]@{
      task_id = $task
      overall_status = 'PASS'
      acceptance_criteria = @(
        [ordered]@{
          id = 'AC1'
          text = 'product.txt exists and contains PASS.'
          status = 'PASS'
          proof = @('product.txt')
          gaps = @()
        }
      )
      changed_files = @('product.txt')
      commands_for_fresh_verifier = @('Get-Content product.txt')
      known_gaps = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $taskDirectory 'evidence.json') -Encoding utf8
    "# Evidence`n`nAC1 PASS: product.txt" | Set-Content -LiteralPath (Join-Path $taskDirectory 'evidence.md') -Encoding utf8
  }
  'verify' {
    [ordered]@{
      task_id = $task
      overall_verdict = 'PASS'
      criteria = @([ordered]@{ id = 'AC1'; status = 'PASS'; reason = 'product.txt contains PASS.' })
      commands_run = @('Get-Content product.txt')
      artifacts_used = @('product.txt')
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $taskDirectory 'verdict.json') -Encoding utf8
  }
}

[ordered]@{
  phase = $phase
  status = 'completed'
  summary = "fake $phase completed"
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $output -Encoding utf8

[ordered]@{ type = 'fake-codex'; phase = $phase } | ConvertTo-Json -Compress
'@

  [System.IO.File]::WriteAllText($fakeCodex, $fakeSource, [System.Text.UTF8Encoding]::new($false))

  $initOutput = & $LoopScript init `
    -RepoRoot $repo `
    -TaskId $taskId `
    -TaskText 'Create product.txt and prove it.' `
    -ActiveBudgetMinutes 5 `
    -IterationTimeoutMinutes 1 `
    -MaxIterations 8 `
    -RetryDelaySeconds 1 `
    -CliUnavailableTimeoutMinutes 1 `
    -MaxConsecutiveFailures 3 `
    -CodexExecutable $fakeCodex
  $initStatus = $initOutput | ConvertFrom-Json
  if ($initStatus.phase -ne 'freeze') { throw 'Init did not create the freeze phase.' }

  New-Item -ItemType File -Path $delayMarker -Force | Out-Null
  $startStatus = (& $LoopScript start -RepoRoot $repo -TaskId $taskId) | ConvertFrom-Json
  $startedSupervisors.Add([int]$startStatus.supervisorPid)

  Wait-Until {
    $state = Read-TestState
    $state -and $state.phase -eq 'build' -and $state.currentIterationActive -and $state.activeChildPid
  } 25 'The fake build iteration did not start.'

  $interruptedState = Read-TestState
  $oldSupervisorPid = [int]$interruptedState.supervisorPid
  $activeChildPid = [int]$interruptedState.activeChildPid
  Stop-Process -Id $oldSupervisorPid -Force
  Wait-Until { -not (Get-Process -Id $oldSupervisorPid -ErrorAction SilentlyContinue) } 5 'The original supervisor did not stop.'
  if (-not (Get-Process -Id $activeChildPid -ErrorAction SilentlyContinue)) {
    throw 'The active Codex child did not survive supervisor interruption.'
  }

  $recoveredStatus = (& $LoopScript start -RepoRoot $repo -TaskId $taskId) | ConvertFrom-Json
  if ([int]$recoveredStatus.supervisorPid -eq $oldSupervisorPid) {
    throw 'Recovery reused the stale supervisor PID.'
  }
  if ([int]$recoveredStatus.activeChildPid -ne $activeChildPid) {
    throw 'Recovery did not preserve the active child identity.'
  }
  $startedSupervisors.Add([int]$recoveredStatus.supervisorPid)

  Wait-Until {
    $state = Read-TestState
    $state -and $state.completed -and -not $state.running
  } 45 'The recovered loop did not complete.'

  $finalState = Read-TestState
  $verdict = Get-Content -LiteralPath (Join-Path $repo ".agent\tasks\$taskId\verdict.json") -Raw -Encoding utf8 | ConvertFrom-Json
  if ($verdict.overall_verdict -ne 'PASS') { throw 'The fake verifier did not produce PASS.' }
  if ([int]$finalState.iterationsStarted -ne 4) { throw "Expected 4 iterations, got $($finalState.iterationsStarted)." }
  if (-not (Test-Path -LiteralPath (Join-Path $repo 'product.txt'))) { throw 'Build artifact is missing.' }

  $testCodexHome = Join-Path $testRoot 'codex-home'
  & $InstallScript -CodexHome $testCodexHome *> $null
  $installedSkill = Join-Path $testCodexHome 'skills\codex-durable-loop'
  if (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'SKILL.md'))) {
    throw 'Installer did not create a usable skill directory.'
  }

  [pscustomobject]@{
    result = 'PASS'
    repo = $repo
    interruptedSupervisorPid = $oldSupervisorPid
    adoptedChildPid = $activeChildPid
    recoveredSupervisorPid = $recoveredStatus.supervisorPid
    iterations = $finalState.iterationsStarted
    completed = $finalState.completed
    verdict = $verdict.overall_verdict
    installedSkill = $installedSkill
  } | ConvertTo-Json -Depth 6
} catch {
  Write-Output "TEST FAILURE: $($_.Exception.Message)"
  $state = Read-TestState
  if ($state) { Write-Output ($state | ConvertTo-Json -Depth 10) }
  $supervisorLog = Join-Path $repo ".agent\durable-loop\$taskId\logs\supervisor.log"
  if (Test-Path -LiteralPath $supervisorLog) {
    Write-Output 'SUPERVISOR LOG:'
    Get-Content -LiteralPath $supervisorLog -Encoding utf8
  }
  $stderrLogs = @(Get-ChildItem -LiteralPath (Split-Path -Parent $supervisorLog) -Filter '*.stderr.log' -ErrorAction SilentlyContinue)
  foreach ($stderrLog in $stderrLogs) {
    Write-Output "STDERR $($stderrLog.Name):"
    Get-Content -LiteralPath $stderrLog.FullName -Encoding utf8
  }
  $hostLogs = @(Get-ChildItem -LiteralPath (Split-Path -Parent $supervisorLog) -Filter 'supervisor-host.*.log' -ErrorAction SilentlyContinue)
  foreach ($hostLog in $hostLogs) {
    Write-Output "HOST $($hostLog.Name):"
    Get-Content -LiteralPath $hostLog.FullName -Encoding utf8
  }
  throw
} finally {
  Stop-TestProcesses
  if (Test-Path -LiteralPath $testRoot) {
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    if (-not $resolvedTestRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove test directory outside the system temp path: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
