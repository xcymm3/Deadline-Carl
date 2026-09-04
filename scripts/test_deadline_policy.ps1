[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deadline_policy.ps1')
# Load function definitions only: tests never dispatch the real supervisor.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'durable_loop.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
$testCount = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:testCount++
}
function New-Forecast {
  return ('{"mandatoryMinutes":{"low":40,"high":50},"coreMinutes":{"low":5,"high":10},"verificationMinutes":{"low":5,"high":10},"riskMinutes":5,"remainingIterations":3,"confidence":"medium","basis":"WI-001 integration remains; recent check took 5 min","polish":null}' | ConvertFrom-Json)
}
function New-State {
  $state = Ensure-StateFields ([pscustomobject]@{}) $config
  $state.phase = 'build'
  $state.selectedStrategy = 'craft'
  $state.forecast = New-Forecast
  $state.forecastStatus = 'valid'
  return $state
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('deadline-policy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $testRoot '.agent/tasks/unit') -Force | Out-Null
try {
  $config = Ensure-ConfigFields ([pscustomobject]@{activeBudgetSeconds=6000; maxIterations=20; iterationTimeoutSeconds=1500; maxTickSeconds=30; repoRoot=$testRoot; taskId='unit'})
  $state = New-State
  Assert ((Get-PlanningDecision $config $state).stage -eq 'craft') 'Full estimate fits -> craft'
  $state.remainingActiveSeconds = 55*60
  Assert ((Get-PlanningDecision $config $state).stage -eq 'focus') 'Uncertain full delivery -> focus'
  $state.remainingActiveSeconds = 40*60
  Assert ((Get-PlanningDecision $config $state).stage -eq 'ship') 'Only core fits -> ship'
  $state.remainingActiveSeconds = 10*60
  Assert ((Get-PlanningDecision $config $state).stage -eq 'last-call') 'Core cannot fit -> last-call'
  # Same remaining amount and work, different original budgets: strategy must not change.
  $state.remainingActiveSeconds = 55*60
  $before = (Get-AdaptiveDecision $config $state).stage
  $config.activeBudgetSeconds = 1000000
  Assert ((Get-AdaptiveDecision $config $state).stage -eq $before) 'Original percentage cannot select a strategy'
  $config.activeBudgetSeconds = 6000
  $state = New-State
  $state.forecast.confidence = 'low'
  Assert ((Get-AdaptiveDecision $config $state).stage -eq 'focus') 'Low confidence forbids craft/polish'
  $state.forecast.mandatoryMinutes.low = -1
  Assert (-not (Test-WorkForecast $state.forecast)) 'Negative estimate rejected'
  $state.forecast = New-Forecast; $state.forecast.coreMinutes.high = 500
  Assert (-not (Test-WorkForecast $state.forecast)) 'Core must be subset of mandatory'
  $state.forecast = New-Forecast; $state.forecast.riskMinutes = [double]::NaN
  Assert (-not (Test-WorkForecast $state.forecast)) 'Nonfinite risk rejected'
  $state.forecast = New-Forecast; $state.forecast.remainingIterations = 1.5
  Assert (-not (Test-WorkForecast $state.forecast)) 'Fractional iteration estimate rejected'
  $state.forecast = New-Forecast; $state.forecast.mandatoryMinutes.high = '50'
  Assert (-not (Test-WorkForecast $state.forecast)) 'Numeric strings must not bypass schema checks'
  $state = New-State
  Receive-WorkForecast $state $config $null $true
  Assert ($state.selectedStrategy -eq 'focus' -and $state.forecastStatus -eq 'missing') 'Legacy/missing forecast conservative fallback'
  Receive-WorkForecast $state $config (New-Forecast) $true
  Assert ($state.selectedStrategy -eq 'focus') 'First forecast does not upgrade'
  Receive-WorkForecast $state $config (New-Forecast) $true
  Assert ($state.selectedStrategy -eq 'craft') 'Second feasible forecast upgrades'
  $samples = $state.promotionSamples
  1..10 | ForEach-Object { $null = Get-PlanningDecision $config $state }
  Assert ($state.promotionSamples -eq $samples) 'Status reads do not increment promotion samples'
  $state.remainingActiveSeconds = 600
  Assert ((Get-PlanningDecision $config $state).stage -eq 'last-call') 'Downgrade requires no extra forecast'
  $state = New-State
  $state.accumulatedActiveSeconds = 4000
  $staleDecision = Get-PlanningDecision $config $state
  Assert ($staleDecision.forecastStatus -eq 'stale' -and $staleDecision.stage -ne 'polish') 'Stale forecast never promotes'
  $state = New-State
  $state.accumulatedActiveSeconds = 600
  Receive-WorkForecast $state $config (New-Forecast) $true
  Assert ($state.forecastCalibration -gt 1) 'Spending time without reducing work calibrates optimism'
  $state.iterationsStarted = 18
  Assert ((Get-AdaptiveDecision $config $state).stage -eq 'last-call') 'Too few starts for proof path'
  $state = New-State
  $config.deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(2).ToString('o')
  Assert ((Get-EffectiveSeconds $config $state) -le 120) 'Absolute deadline constrains active time'
  $config.activeBudgetSeconds += 5000
  Assert ((Get-EffectiveSeconds $config $state) -le 120) 'Active extension never extends absolute deadline'
  $config.deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
  Assert ((Get-EffectiveSeconds $config $state) -eq 0) 'Expired absolute deadline has zero capacity'
  $config.deadlineUtc = $null
  $state = New-State
  $state.implementationReady = $true
  $state.feasibleSamples = 2
  $state.forecast.mandatoryMinutes = [pscustomobject]@{low=0;high=0}
  $state.forecast.coreMinutes = [pscustomobject]@{low=0;high=0}
  $state.forecast.polish = [pscustomobject]@{id='Q1';scopeReference='Improve hit feedback without changing simple geometry';minutes=5;value='Readable damage';stopCondition='Abort optional work if regression appears'}
  [IO.File]::WriteAllText((Join-Path $testRoot '.agent/tasks/unit/spec.md'), "# Spec`n## Quality opportunities`n- Q1: Improve hit feedback without changing simple geometry`n")
  Assert ((Get-PlanningDecision $config $state).stage -eq 'polish') 'Eligible frozen quality opportunity enters polish'
  $state.forecast.polish.scopeReference = 'Add unrelated mechanics'
  Assert ((Get-AdaptiveDecision $config $state).stage -eq 'craft') 'Unfrozen opportunity rejected'
  $state.forecast.polish.scopeReference = 'Improve hit feedback without changing simple geometry'
  $state.forecast.mandatoryMinutes.high = 1
  Assert ((Get-AdaptiveDecision $config $state).stage -eq 'craft') 'Forecasted mandatory gaps forbid polish despite ready progress'
  $state.forecast.mandatoryMinutes.high = 0
  $state.polishAttempts = @('Q1')
  Assert ((Get-AdaptiveDecision $config $state).stage -eq 'craft') 'Polish cannot repeat indefinitely'
  $state.polishAttempts = @(); $state.phase = 'verify'
  Assert ((Get-AdaptiveDecision $config $state).stage -eq 'craft') 'Verifier never polishes'
  $state.phase = 'build'; $state.implementationReady = $false
  Assert ((Get-AdaptiveDecision $config $state).stage -eq 'craft') 'Incomplete mandatory implementation forbids polish'
  $state = New-State
  $state.accumulatedActiveSeconds = 100
  $state.lastTickUtc = [DateTimeOffset]::UtcNow.AddSeconds(-3).ToString('o')
  Open-StrategyInterval $state 'craft' ([pscustomobject]@{reason='test'}) $state.lastTickUtc
  $state = Update-Elapsed $state $config
  Assert ($state.strategyHistory[-1].activeSeconds -ge 3 -and $state.strategyHistory[-1].activeSeconds -lt 5) 'Intervals count actual charged elapsed time'
  Close-StrategyInterval $state (Get-UtcNowIso) 'pause'
  $oldSeconds = $state.strategyHistory[0].activeSeconds
  $state.lastTickUtc = $null
  $state = Update-Elapsed $state $config
  Assert ($state.strategyHistory[0].activeSeconds -eq $oldSeconds) 'Paused time not charged to previous strategy'
  Open-StrategyInterval $state 'focus' ([pscustomobject]@{reason='resume'})
  Assert (@($state.strategyHistory).Count -eq 2) 'Resume creates new UTC interval'
  Assert ([Math]::Abs((Get-BudgetAssessment $state $config).unrecordedActiveSeconds - 100) -lt 0.01) 'Legacy time remains explicitly unknown'
  $state.blocked = $true
  Assert ((Get-BudgetAssessment $state $config).assessment -eq 'blocked-not-a-budget-conclusion') 'Blocker is not called insufficient budget'
  $state.blocked = $false; $state.stopReason = 'active-budget-exhausted'
  Assert ((Get-BudgetAssessment $state $config).assessment -eq 'time-exhausted-with-gaps') 'Time exhaustion labeled with gaps'
  $state.completed = $true
  Assert ((Get-BudgetAssessment $state $config).assessment -eq 'completed-within-budget') 'Completed with headroom is not called waste'
  $config.deliveryMode = 'proof-first'
  $state.completed = $false
  Assert ((Get-DeadlineContext $config $state).stage -eq 'proof-first') 'Proof-first retains its separate planning mode'
  $state.completed = $true
  Assert ((Get-DeadlineContext $config $state).stage -eq 'complete') 'Completed state takes precedence over planning modes'
  [pscustomobject]@{ result='PASS'; assertions=$testCount } | ConvertTo-Json
} finally {
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  if ((Split-Path $resolvedTestRoot -Parent) -ne ([IO.Path]::GetTempPath()).TrimEnd('\') -or (Split-Path $resolvedTestRoot -Leaf) -notlike 'deadline-policy-*') { throw 'Unsafe test cleanup path' }
  Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
