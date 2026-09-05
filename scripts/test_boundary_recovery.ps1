[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$LoopScript = Join-Path $PSScriptRoot 'durable_loop.ps1'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase "deadline-carl-boundary-$([Guid]::NewGuid().ToString('N'))"
$repo = Join-Path $testRoot 'repo'
$taskId = 'repair-test'
$statePath = Join-Path $repo ".agent\durable-loop\$taskId\runtime.json"
$taskDirectory = Join-Path $repo ".agent\tasks\$taskId"

function Read-State {
  Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
}

function Write-State([object]$State) {
  [IO.File]::WriteAllText($statePath, ($State | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}

function Set-BlockedViolation([string]$Violation) {
  $state = Read-State
  $state.running = $false
  $state.currentIterationActive = $false
  $state.activeChildPid = $null
  $state.activeChildStartedAtUtc = $null
  $state.blocked = $true
  $state.blockedReason = "test boundary violation: $Violation"
  $state.stopReason = 'blocked'
  $state.phase = 'build'
  $state.lastWriteBoundaryStatus = 'fail'
  $state.lastWriteBoundaryViolations = @($Violation)
  $state.consecutiveFailures = 2
  Write-State $state
}

function Assert-RepairRefused([string]$Violation, [string]$ExpectedText) {
  Set-BlockedViolation $Violation
  $refused = $false
  try {
    & $LoopScript repair-boundary -RepoRoot $repo -TaskId $taskId *> $null
  } catch {
    $refused = $_.Exception.Message.Contains($ExpectedText)
  }
  if (-not $refused) { throw "repair-boundary did not refuse $Violation with the expected explanation." }
}

try {
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  & git -C $repo init *> $null
  & git -C $repo config user.email 'boundary-test@example.invalid'
  & git -C $repo config user.name 'Boundary Recovery Test'

  & $LoopScript init `
    -RepoRoot $repo `
    -TaskId $taskId `
    -TaskText 'Exercise safe boundary repair.' `
    -ActiveBudgetMinutes 5 `
    -IterationTimeoutMinutes 1 `
    -MaxIterations 3 `
    -MaxConsecutiveFailures 3 *> $null

  $extraPath = Join-Path $taskDirectory 'ui-build-plan.md'
  '# useful plan preserved by quarantine' | Set-Content -LiteralPath $extraPath -Encoding utf8
  Set-BlockedViolation 'created:ui-build-plan.md'

  $repaired = (& $LoopScript repair-boundary -RepoRoot $repo -TaskId $taskId) | ConvertFrom-Json
  if ($repaired.blocked -or $repaired.lastWriteBoundaryStatus -ne 'repaired') {
    throw 'repair-boundary did not clear the eligible blocker.'
  }
  if ($repaired.running) { throw 'repair-boundary unexpectedly started the supervisor.' }
  if (Test-Path -LiteralPath $extraPath) { throw 'repair-boundary left the extra file in the formal task directory.' }
  if (-not $repaired.lastWriteBoundaryRecovery -or
      -not (Test-Path -LiteralPath $repaired.lastWriteBoundaryRecovery.manifestPath)) {
    throw 'repair-boundary did not expose a recovery manifest.'
  }
  $manifest = Get-Content -LiteralPath $repaired.lastWriteBoundaryRecovery.manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
  if ($manifest.mode -ne 'repair-boundary' -or $manifest.items[0].relativePath -ne 'ui-build-plan.md') {
    throw 'repair-boundary manifest lost its recovery mode or original path.'
  }
  if (-not $manifest.items[0].sha256 -or -not (Test-Path -LiteralPath $manifest.items[0].destinationPath)) {
    throw 'repair-boundary manifest lost the recovered file or its digest.'
  }
  if ([int]$repaired.lastWriteBoundaryRecovery.failuresBeforeRepair -ne 2) {
    throw 'repair-boundary did not retain the pre-repair failure count.'
  }

  $progressPath = Join-Path $taskDirectory 'progress.json'
  $progressHash = (Get-FileHash -LiteralPath $progressPath -Algorithm SHA256).Hash
  Assert-RepairRefused 'modified:progress.json' 'only accepts violations composed entirely of safe created files'
  if ((Get-FileHash -LiteralPath $progressPath -Algorithm SHA256).Hash -ne $progressHash) {
    throw 'A refused modified-artifact repair changed the protected file.'
  }

  Assert-RepairRefused 'deleted:progress.json' 'only accepts violations composed entirely of safe created files'
  Assert-RepairRefused 'created:missing-plan.md' 'Created file is missing or unsafe'
  Assert-RepairRefused 'created:../escape.md' 'only accepts violations composed entirely of safe created files'

  [pscustomobject]@{
    result = 'PASS'
    repairedPath = $manifest.items[0].destinationPath
    manifest = $repaired.lastWriteBoundaryRecovery.manifestPath
    refusalCases = 4
  } | ConvertTo-Json -Depth 5
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    $resolved = (Resolve-Path -LiteralPath $testRoot).Path
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'deadline-carl-boundary-*') {
      throw "Refusing to remove unsafe boundary test path: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
