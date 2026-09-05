[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
$LoopScript = Join-Path $PSScriptRoot 'durable_loop.ps1'
$InstallScript = Join-Path $PSScriptRoot 'install_skill.ps1'
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase "deadline-carl-test-$([Guid]::NewGuid().ToString('N'))"
$repo = Join-Path $testRoot 'repo'
$taskId = 'recovery-test'
$statePath = Join-Path $repo ".agent\durable-loop\$taskId\runtime.json"
$delayMarker = Join-Path $repo ".agent\durable-loop\$taskId\delay-build-once"
$createdBoundaryMarker = Join-Path $repo ".agent\durable-loop\$taskId\create-extra-build-file-once"
$writeBoundaryMarker = Join-Path $repo ".agent\durable-loop\$taskId\violate-verify-once"
$protectedRawPath = Join-Path $repo ".agent\tasks\$taskId\raw\test-unit.txt"
$fakeCodex = Join-Path $testRoot 'fake-codex.ps1'
$startedSupervisors = [System.Collections.Generic.List[int]]::new()

function Read-TestState {
  if (-not (Test-Path -LiteralPath $statePath)) { return $null }
  try {
    return Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
  } catch {
    return $null
  }
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
  'dist/' | Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Encoding utf8

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
$stage = [regex]::Match($prompt, 'Deadline stage: `([^`]+)`').Groups[1].Value
$resultStatus = 'completed'
$taskDirectory = Join-Path $root ".agent\tasks\$task"
$runtimeDirectory = Join-Path $root ".agent\durable-loop\$task"
$marker = Join-Path $runtimeDirectory 'delay-build-once'
$createdBoundaryMarker = Join-Path $runtimeDirectory 'create-extra-build-file-once'
$writeBoundaryMarker = Join-Path $runtimeDirectory 'violate-verify-once'
$scratchDirectory = $env:DEADLINE_CARL_OUTPUT_DIR

if (-not $scratchDirectory -or -not (Test-Path -LiteralPath $scratchDirectory)) { exit 3 }
if ($env:DEADLINE_CARL_TASK_ID -ne $task -or $env:DEADLINE_CARL_PHASE -ne $phase) { exit 4 }
if ($env:DEADLINE_CARL_FORMAL_TASK_DIR -ne $taskDirectory -or $env:DEADLINE_CARL_SCRATCH_DIR -ne $scratchDirectory) { exit 5 }
try { $allowedWrites = @($env:DEADLINE_CARL_ALLOWED_TASK_WRITES | ConvertFrom-Json) } catch { exit 6 }
$expectedWrites = switch ($phase) {
  'freeze' { @('deadline-report.md', 'spec.md') }
  'build' { @('deadline-report.md', 'progress.json') }
  'evidence' { @('deadline-report.md', 'evidence.md', 'evidence.json', 'raw/**') }
  'verify' { @('deadline-report.md', 'verdict.json', 'problems.md') }
  'fix' { @('deadline-report.md', 'progress.json', 'evidence.md', 'evidence.json', 'raw/**') }
}
if (($allowedWrites -join '|') -ne ($expectedWrites -join '|')) { exit 7 }
"scratch $phase" | Set-Content -LiteralPath (Join-Path $scratchDirectory 'worker-output.txt') -Encoding utf8

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
### AC1 - product.txt exists and contains PASS

## Work items
| Item | Description | Acceptance criteria |
| --- | --- | --- |
| WI-001 | Create and prove product.txt | AC1 |

## Constraints
- Preserve existing work.

## Non-goals
- No unrelated edits.

## Quality opportunities
- Q1: Add a readable quality marker without changing product behavior

## Verification plan
- Check product.txt.
"@ | Set-Content -LiteralPath (Join-Path $taskDirectory 'spec.md') -Encoding utf8
  }
  'build' {
    if (Test-Path -LiteralPath $createdBoundaryMarker) {
      Remove-Item -LiteralPath $createdBoundaryMarker
      '# Hallmark file plan that belongs in scratch' | Set-Content -LiteralPath (Join-Path $taskDirectory 'ui-build-plan.md') -Encoding utf8
    }
    if ($stage -eq 'polish') { 'quality checked' | Set-Content -LiteralPath (Join-Path $root 'quality.txt') -Encoding utf8 }
    'PASS' | Set-Content -LiteralPath (Join-Path $root 'product.txt') -Encoding utf8
    $progressPath = Join-Path $taskDirectory 'progress.json'
    $progress = Get-Content -LiteralPath $progressPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($progress.items[0].state -eq 'pending') {
      $progress.items[0].state = 'in_progress'
      $progress.items[0].note = 'Product created; final check remains.'
      $progress.items[0].proof = @('product.txt')
      $resultStatus = 'progressed'
    } else {
      $progress.items[0].state = 'implemented'
      $progress.items[0].note = 'Product and focused check complete.'
      $progress.items[0].proof = @('product.txt')
    }
    $progress | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $progressPath -Encoding utf8
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
    if (Test-Path -LiteralPath $writeBoundaryMarker) {
      Remove-Item -LiteralPath $writeBoundaryMarker
      'verifier must not overwrite formal evidence' | Set-Content -LiteralPath (Join-Path $taskDirectory 'raw\test-unit.txt') -Encoding utf8
    }
    [ordered]@{
      task_id = $task
      overall_verdict = 'PASS'
      criteria = @([ordered]@{ id = 'AC1'; status = 'PASS'; reason = 'product.txt contains PASS.' })
      commands_run = @('Get-Content product.txt')
      artifacts_used = @('product.txt')
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $taskDirectory 'verdict.json') -Encoding utf8
    @"
# Problems: $task

## Verification summary
- Verdict: PASS
- Open problems: 0

No FAIL or UNKNOWN acceptance criteria remain.
"@ | Set-Content -LiteralPath (Join-Path $taskDirectory 'problems.md') -Encoding utf8
  }
}

$forecast = [ordered]@{
  mandatoryMinutes = @{low=1;high=2}; coreMinutes = @{low=0.5;high=1}
  verificationMinutes = @{low=0.5;high=1}; riskMinutes=0.5; remainingIterations=3
  confidence='medium'; basis='WI-001 small product and measured focused check; fake integration fixture'; polish=$null
}
if ($phase -eq 'build' -and $resultStatus -eq 'completed') {
  $forecast.mandatoryMinutes = @{low=0;high=0}; $forecast.coreMinutes = @{low=0;high=0}
  $forecast.polish = @{id='Q1';scopeReference='Add a readable quality marker without changing product behavior';minutes=0.5;value='Readable output';stopCondition='Stop on regression, preserve product'}
}
[ordered]@{
  phase = $phase
  status = $resultStatus
  summary = "fake $phase $resultStatus"
  forecast = $forecast
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
    -DeliveryMode deadline-aware `
    -CodexExecutable $fakeCodex
  $initStatus = $initOutput | ConvertFrom-Json
  $testConfigPath = Join-Path $repo ".agent/durable-loop/$taskId/config.json"
  $testConfig = Get-Content -LiteralPath $testConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
  $testConfig.heartbeatSeconds = 1
  [IO.File]::WriteAllText($testConfigPath, ($testConfig | ConvertTo-Json -Depth 10))
  if ($initStatus.phase -ne 'freeze') { throw 'Init did not create the freeze phase.' }
  if ($initStatus.deliveryMode -ne 'deadline-aware') { throw 'Init did not enable deadline-aware delivery.' }
  if (-not $initStatus.gitHygiene.ignore_rules_ready) { throw 'Init did not install the local-state ignore rules.' }
  if ($initStatus.gitHygiene.proof_artifacts_ignored) { throw 'Init incorrectly ignored formal proof artifacts.' }
  if (-not (Test-Path -LiteralPath $initStatus.scratchDirectory)) { throw 'Init did not create the scratch directory.' }
  $protectedRawBefore = [System.IO.File]::ReadAllBytes($protectedRawPath)
  $gitignore = Get-Content -LiteralPath (Join-Path $repo '.gitignore') -Raw -Encoding utf8
  foreach ($entry in @('/.agent/durable-loop/', '/.agent/deadline-carl-scratch/', '/.agent/tasks/*/.init-in-progress')) {
    if (@($gitignore -split '\r?\n') -notcontains $entry) {
      throw "Init did not exclude Deadline-Carl local state: $entry"
    }
  }

  $extendedStatus = (& $LoopScript extend `
    -RepoRoot $repo `
    -TaskId $taskId `
    -AdditionalBudgetMinutes 2) | ConvertFrom-Json
  if ([int]$extendedStatus.activeBudgetSeconds -ne 420) { throw 'Budget extension did not update the active-time limit.' }
  if ([int]$extendedStatus.budgetExtensionSeconds -ne 120) { throw 'Budget extension was not recorded.' }
  if ([int]$extendedStatus.remainingActiveSeconds -ne 420) { throw 'Budget extension did not refresh remaining active time.' }

  $pressureState = Read-TestState
  $pressureState.accumulatedActiveSeconds = 400
  $pressureState.remainingActiveSeconds = 20
  $pressureState | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
  $lastCallStatus = (& $LoopScript status -RepoRoot $repo -TaskId $taskId) | ConvertFrom-Json
  if ($lastCallStatus.deadlineStage -ne 'last-call') { throw 'Low remaining budget did not select last-call.' }
  if ([double]$lastCallStatus.remainingActivePercent -ge 5) { throw 'Last-call status reported an invalid remaining percentage.' }

  $recoveredBudgetStatus = (& $LoopScript extend `
    -RepoRoot $repo `
    -TaskId $taskId `
    -AdditionalBudgetMinutes 10) | ConvertFrom-Json
  if ([int]$recoveredBudgetStatus.activeBudgetSeconds -ne 1020) { throw 'Second budget extension did not preserve accumulated time.' }
  if ([int]$recoveredBudgetStatus.budgetExtensionSeconds -ne 720) { throw 'Cumulative budget extensions were not recorded.' }
  if ($recoveredBudgetStatus.deadlineStage -ne 'focus') { throw 'Without estimates, added time must not imply craft readiness.' }

  New-Item -ItemType File -Path $delayMarker -Force | Out-Null
  New-Item -ItemType File -Path $createdBoundaryMarker -Force | Out-Null
  New-Item -ItemType File -Path $writeBoundaryMarker -Force | Out-Null
  $startStatus = (& $LoopScript start -RepoRoot $repo -TaskId $taskId) | ConvertFrom-Json
  $startedSupervisors.Add([int]$startStatus.supervisorPid)

  $extendWhileRunningRejected = $false
  try {
    & $LoopScript extend -RepoRoot $repo -TaskId $taskId -AdditionalBudgetMinutes 1 *> $null
  } catch {
    $extendWhileRunningRejected = $true
  }
  if (-not $extendWhileRunningRejected) { throw 'Budget extension must be rejected while the supervisor is running.' }

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
    $state -and $state.blocked -and -not $state.running
  } 90 'The recovered loop did not stop on the verifier write-boundary violation.'

  $blockedStatus = (& $LoopScript status -RepoRoot $repo -TaskId $taskId) | ConvertFrom-Json
  if ($blockedStatus.completed) { throw 'A verifier write-boundary violation was incorrectly accepted.' }
  if ($blockedStatus.lastWriteBoundaryStatus -ne 'fail') { throw 'Status did not report the failed write boundary.' }
  if (-not (@($blockedStatus.lastWriteBoundaryViolations) -contains 'modified:raw/test-unit.txt')) {
    throw 'Status did not identify the verifier-modified formal evidence file.'
  }
  $quarantinedIteration = @($blockedStatus.iterationHistory | Where-Object writeBoundaryStatus -eq 'quarantined')
  if ($quarantinedIteration.Count -ne 1) { throw 'Created-only task file did not produce exactly one quarantined retry.' }
  if (-not (@($quarantinedIteration[0].writeBoundaryViolations) -contains 'created:ui-build-plan.md')) {
    throw 'Quarantined retry did not retain the original created-file violation.'
  }
  $automaticRecovery = @($blockedStatus.writeBoundaryRecoveryHistory | Where-Object mode -eq 'automatic')
  if ($automaticRecovery.Count -ne 1 -or -not (Test-Path -LiteralPath $automaticRecovery[0].manifestPath)) {
    throw 'Automatic quarantine did not publish a recovery manifest.'
  }
  if (Test-Path -LiteralPath (Join-Path $repo ".agent\tasks\$taskId\ui-build-plan.md")) {
    throw 'Automatic quarantine left the extra file in the formal task directory.'
  }
  $automaticManifest = Get-Content -LiteralPath $automaticRecovery[0].manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
  if ($automaticManifest.items[0].relativePath -ne 'ui-build-plan.md' -or
      -not (Test-Path -LiteralPath $automaticManifest.items[0].destinationPath)) {
    throw 'Automatic quarantine manifest is incomplete or its recovered file is missing.'
  }

  [System.IO.File]::WriteAllBytes($protectedRawPath, $protectedRawBefore)
  $resumedStatus = (& $LoopScript start -RepoRoot $repo -TaskId $taskId -Force) | ConvertFrom-Json
  $startedSupervisors.Add([int]$resumedStatus.supervisorPid)
  Wait-Until {
    $state = Read-TestState
    $state -and $state.completed -and -not $state.running
  } 60 'The loop did not complete after repairing the protected evidence and resuming.'

  $finalState = Read-TestState
  $verdict = Get-Content -LiteralPath (Join-Path $repo ".agent\tasks\$taskId\verdict.json") -Raw -Encoding utf8 | ConvertFrom-Json
  $problems = Get-Content -LiteralPath (Join-Path $repo ".agent\tasks\$taskId\problems.md") -Raw -Encoding utf8
  if ($verdict.overall_verdict -ne 'PASS') { throw 'The fake verifier did not produce PASS.' }
  if ($problems -notmatch '(?m)^- Verdict: PASS\s*$' -or $problems -notmatch '(?m)^- Open problems: 0\s*$') {
    throw 'The fake verifier did not replace problems.md with a zero-problem PASS report.'
  }
  if ($problems -match '(?m)^###\s+') { throw 'The PASS problems report preserved a stale problem section.' }
  if ([int]$finalState.iterationsStarted -ne 6) { throw "Expected 6 iterations including the quarantined retry, got $($finalState.iterationsStarted)." }
  if (@($finalState.iterationHistory | Where-Object strategy -eq 'polish').Count -ne 0) { throw 'An untrusted quarantined forecast incorrectly unlocked polish.' }
  if (@($finalState.iterationHistory).Count -ne 6) { throw 'Iteration history lost an outcome across recovery.' }
  if (@($finalState.strategyHistory | Where-Object { -not $_.endedAtUtc }).Count) { throw 'Stopped history has an unclosed interval.' }
  $historySeconds = ($finalState.strategyHistory | Measure-Object activeSeconds -Sum).Sum + $finalState.historyBaselineActiveSeconds
  if ([Math]::Abs($historySeconds - $finalState.accumulatedActiveSeconds) -gt 0.01) { throw 'Strategy durations do not reconcile with charged active time.' }
  foreach ($interval in @($finalState.strategyHistory)) {
    $span = ([DateTimeOffset]$interval.endedAtUtc - [DateTimeOffset]$interval.startedAtUtc).TotalSeconds
    if ($span -lt 0 -or $interval.activeSeconds -gt ($span + 0.1)) { throw "History charged time outside interval: $($interval.stage) $($interval.startedAtUtc) active=$($interval.activeSeconds) span=$span" }
  }
  if (@($finalState.strategyHistory | Where-Object endReason -eq 'supervisor-interrupted-last-observed').Count -ne 1) { throw 'Interrupted interval not recorded.' }
  if (-not (Test-Path -LiteralPath (Join-Path $repo 'product.txt'))) { throw 'Build artifact is missing.' }
  if ($finalState.stopReason -ne 'completed') { throw 'Completed loop did not record a completed stop reason.' }
  $completedStatus = (& $LoopScript status -RepoRoot $repo -TaskId $taskId) | ConvertFrom-Json
  if ($completedStatus.deadlineStage -ne 'complete') { throw 'Completed status did not report the complete deadline stage.' }
  if ($completedStatus.progressDisplay.implementation -notmatch '1/1$') { throw 'Status did not report implementation progress as 1/1.' }
  if ($completedStatus.progressDisplay.verification -notmatch '1/1$') { throw 'Status did not report verification progress as 1/1.' }
  if ($completedStatus.progressDisplay.acceptance -notmatch '1/1$') { throw 'Status did not report acceptance progress as 1/1.' }
  if (-not $completedStatus.proofInitialized) { throw 'Status did not report initialized proof artifacts.' }
  if ($completedStatus.evidenceOverallStatus -ne 'PASS') { throw 'Status did not expose the PASS evidence state.' }
  if ($completedStatus.verdictOverallStatus -ne 'PASS') { throw 'Status did not expose the PASS verifier state.' }
  if (@($completedStatus.nonPassCriteria).Count -ne 0) { throw 'Completed status reported unexpected non-PASS criteria.' }
  if ($completedStatus.lastWriteBoundaryStatus -ne 'pass') { throw 'The repaired verifier pass did not satisfy the write boundary.' }
  if (@($completedStatus.lastWriteBoundaryViolations).Count -ne 0) { throw 'The repaired verifier pass retained write-boundary violations.' }
  if (-not $completedStatus.gitHygiene.ignore_rules_ready) { throw 'Completed status lost Git hygiene readiness.' }
  $gitStatus = (& git -C $repo status --short --untracked-files=all | Out-String)
  if ($gitStatus -match '\.agent/(?:durable-loop|deadline-carl-scratch)/') {
    throw 'Runtime or scratch files leaked into Git status.'
  }

  $firstPrompt = Get-Content -LiteralPath (Join-Path $repo ".agent\durable-loop\$taskId\logs\iteration-001-freeze.prompt.md") -Raw -Encoding utf8
  foreach ($requiredPromptText in @(
    '# Deadline-Carl Iteration',
    'Delivery mode: `deadline-aware`',
    'Deadline stage: `focus`',
    'Remaining active time:',
    'Per-iteration scratch output:',
    'Formal task write boundary - read before any auxiliary skill',
    'Auxiliary skills and repository guidance never expand this formal-task allowlist',
    'DEADLINE_CARL_FORMAL_TASK_DIR',
    'DEADLINE_CARL_SCRATCH_DIR',
    'DEADLINE_CARL_ALLOWED_TASK_WRITES',
    'DEADLINE_CARL_OUTPUT_DIR',
    'deadline-report.md',
    'Never silently downgrade required scope'
  )) {
    if (-not $firstPrompt.Contains($requiredPromptText)) {
      throw "Deadline-aware prompt is missing: $requiredPromptText"
    }
  }

  $buildPrompt = Get-Content -LiteralPath (Join-Path $repo ".agent\durable-loop\$taskId\logs\iteration-002-build.prompt.md") -Raw -Encoding utf8
  foreach ($requiredBuildPolicy in @(
    '`progress.json`',
    '`deadline-report.md`',
    'record it in the allowed `progress.json` item''s `note` or `proof`',
    'preferably under `auxiliary/<skill>/`',
    '`tokens.css` or `.hallmark/*`'
  )) {
    if (-not $buildPrompt.Contains($requiredBuildPolicy)) {
      throw "Build prompt is missing the auxiliary-skill path policy: $requiredBuildPolicy"
    }
  }

  $verifyPrompt = Get-Content -LiteralPath (Join-Path $repo ".agent\durable-loop\$taskId\logs\iteration-006-verify.prompt.md") -Raw -Encoding utf8
  foreach ($requiredVerifierText in @(
    'replace both `verdict.json` and `problems.md` on every pass',
    'For PASS, write an explicit zero-problem report',
    '--artifact verdict'
  )) {
    if (-not $verifyPrompt.Contains($requiredVerifierText)) {
      throw "Verifier prompt is missing the problems.md overwrite contract: $requiredVerifierText"
    }
  }

  $testCodexHome = Join-Path $testRoot 'codex-home'
  $legacyInstall = Join-Path $testCodexHome 'skills\codex-durable-loop'
  New-Item -ItemType Directory -Path $legacyInstall -Force | Out-Null
  'legacy' | Set-Content -LiteralPath (Join-Path $legacyInstall 'marker.txt') -Encoding utf8
  & $InstallScript -CodexHome $testCodexHome -Force *> $null
  $installedSkill = Join-Path $testCodexHome 'skills\deadline-carl'
  if (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'SKILL.md'))) {
    throw 'Installer did not create a usable skill directory.'
  }
  $legacyBackups = @(Get-ChildItem -LiteralPath (Join-Path $testCodexHome 'skills') -Directory -Filter 'codex-durable-loop.backup.*')
  if ($legacyBackups.Count -ne 1) { throw 'Installer did not preserve exactly one legacy installation backup.' }

  $installedInstaller = Join-Path $installedSkill 'scripts\install_skill.ps1'
  & $installedInstaller -CodexHome $testCodexHome -Force *> $null
  if (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'SKILL.md'))) {
    throw 'Self-update did not restore a usable skill directory.'
  }
  $deadlineBackups = @(Get-ChildItem -LiteralPath (Join-Path $testCodexHome 'skills') -Directory -Filter 'deadline-carl.backup.*')
  if ($deadlineBackups.Count -ne 1) { throw 'Self-update did not preserve exactly one existing installation backup.' }

  $beforeStatusHash = (Get-FileHash -LiteralPath $statePath).Hash
  & $LoopScript status -RepoRoot $repo -TaskId $taskId | Out-Null
  if ((Get-FileHash -LiteralPath $statePath).Hash -ne $beforeStatusHash) { throw 'Status read mutated persisted history.' }

  $fullHistory = (& $LoopScript history -RepoRoot $repo -TaskId $taskId) | ConvertFrom-Json
  if (@($fullHistory.iterationHistory).Count -ne 6) { throw 'History command truncated full iterations.' }
  if (@($completedStatus.iterationHistory).Count -gt 5 -or @($completedStatus.strategyHistory).Count -gt 10) { throw 'Status should bound history output.' }

  [pscustomobject]@{
    result = 'PASS'
    repo = $repo
    interruptedSupervisorPid = $oldSupervisorPid
    adoptedChildPid = $activeChildPid
    recoveredSupervisorPid = $recoveredStatus.supervisorPid
    iterations = $finalState.iterationsStarted
    completed = $finalState.completed
    verdict = $verdict.overall_verdict
    blockedWriteBoundary = @($blockedStatus.lastWriteBoundaryViolations)
    gitHygiene = $completedStatus.gitHygiene
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
  foreach ($debugArtifact in @('spec.md', 'plan.json', 'progress.json')) {
    $debugPath = Join-Path $repo ".agent\tasks\$taskId\$debugArtifact"
    if (Test-Path -LiteralPath $debugPath) {
      Write-Output "TASK ARTIFACT $debugArtifact`:"
      Get-Content -LiteralPath $debugPath -Encoding utf8
    }
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
