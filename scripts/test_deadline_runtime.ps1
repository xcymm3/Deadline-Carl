[CmdletBinding()]
param([switch]$AdoptWorker)
$ErrorActionPreference = 'Stop'
$loop = Join-Path $PSScriptRoot 'durable_loop.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('deadline-expiry-' + [guid]::NewGuid().ToString('N'))
$statePath = Join-Path $testRoot '.agent/durable-loop/expiry/runtime.json'
$passed = $false
try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  & git -C $testRoot init *> $null
  $sleeper = Join-Path $testRoot 'sleeper.ps1'
  [IO.File]::WriteAllText($sleeper, 'Start-Sleep -Seconds 60')
  & $loop init -RepoRoot $testRoot -TaskId expiry -TaskText 'Deadline runtime fixture' -ActiveBudgetMinutes 5 -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(30).ToString('o')) -CodexExecutable $sleeper | Out-Null
  $started = (& $loop start -RepoRoot $testRoot -TaskId expiry) | ConvertFrom-Json
  if ($AdoptWorker) {
    $adoptUntil = [DateTimeOffset]::UtcNow.AddSeconds(10)
    do {
      Start-Sleep -Milliseconds 100
      $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
    } while (-not $state.currentIterationActive -and [DateTimeOffset]::UtcNow -lt $adoptUntil)
    if (-not $state.activeChildPid) { throw 'No active test Worker available to adopt.' }
    Stop-Process -Id ([int]$state.supervisorPid) -Force
    $null = & $loop start -RepoRoot $testRoot -TaskId expiry
  }
  $waitUntil = [DateTimeOffset]::UtcNow.AddSeconds(40)
  do {
    Start-Sleep -Milliseconds 250
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
  } while ($state.running -and [DateTimeOffset]::UtcNow -lt $waitUntil)
  if ($state.running) { throw 'Deadline supervisor failed to stop within 40 seconds.' }
  if ($state.stopReason -ne 'absolute-deadline-reached' -or $state.completed -or $state.lastIterationExitCode -ne 124) { throw 'Expired worker not reported as incomplete timeout.' }
  if ($state.activeChildPid -or $state.remainingActiveSeconds -le 0) { throw 'Child ownership or active budget incorrect after wall expiry.' }
  $history = (& $loop history -RepoRoot $testRoot -TaskId expiry) | ConvertFrom-Json
  if ($history.budgetAssessment.assessment -ne 'time-exhausted-with-gaps') { throw 'History lost absolute deadline outcome.' }
  $expiredStartRejected = $false
  try { & $loop start -RepoRoot $testRoot -TaskId expiry *> $null } catch { $expiredStartRejected = $true }
  if (-not $expiredStartRejected) { throw 'Expired deadline allowed another start.' }
  $passed = $true
  [pscustomobject]@{result='PASS';adopted=[bool]$AdoptWorker;stopReason=$state.stopReason;exitCode=$state.lastIterationExitCode;remainingActiveSeconds=$state.remainingActiveSeconds} | ConvertTo-Json
} catch {
  Write-Output "Failed fixture retained: $testRoot"
  if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Encoding utf8 }
  Get-ChildItem -LiteralPath (Join-Path $testRoot '.agent/durable-loop/expiry/logs') -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_.FullName; Get-Content -LiteralPath $_.FullName -Encoding utf8 }
  throw
} finally {
  if (Test-Path -LiteralPath $statePath) {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($testProcessId in @($state.activeChildPid, $state.supervisorPid)) {
      if ($testProcessId) { Stop-Process -Id ([int]$testProcessId) -Force -ErrorAction SilentlyContinue }
    }
  }
  if ($passed) {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ((Split-Path $resolvedTestRoot -Parent) -ne ([IO.Path]::GetTempPath()).TrimEnd('\') -or (Split-Path $resolvedTestRoot -Leaf) -notlike 'deadline-expiry-*') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
