# Adaptive planning is separate from proof gates. Forecasts never establish PASS.
function Initialize-AdaptiveState([object]$State) {
  $defaults = [ordered]@{
    forecast = $null; forecastStatus = 'missing'; forecastAtActiveSeconds = 0
    forecastRevision = 0; forecastCalibration = 1.0; promotionCandidate = ''; promotionSamples = 0; feasibleSamples = 0
    selectedStrategy = 'focus'; strategyHistory = @(); iterationHistory = @()
    historyStartedAtUtc = $null; historyBaselineActiveSeconds = 0
    iterationStartActiveSeconds = 0; iterationStrategy = $null; iterationForecast = $null
    iterationLimitSeconds = $null; polishAttempts = @(); implementationReady = $false
    budgetEvents = @()
  }
  foreach ($entry in $defaults.GetEnumerator()) {
    if ($null -eq $State.PSObject.Properties[$entry.Key]) {
      $State | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
    }
  }
  if (-not $State.historyStartedAtUtc -and @($State.strategyHistory).Count -eq 0) {
    $State.historyBaselineActiveSeconds = $State.accumulatedActiveSeconds
  }
}

function Get-EffectiveSeconds([object]$Config, [object]$State) {
  $seconds = [Math]::Max(0.0, [double]$State.remainingActiveSeconds)
  if ($Config.deadlineUtc) {
    $wall = ((ConvertTo-DateTimeOffsetValue $Config.deadlineUtc) - [DateTimeOffset]::UtcNow).TotalSeconds
    $seconds = [Math]::Min($seconds, [Math]::Max(0.0, $wall))
  }
  return $seconds
}

function Test-WorkForecast([object]$Forecast) {
  if ($null -eq $Forecast) { return $false }
  foreach ($name in @('mandatoryMinutes', 'coreMinutes', 'verificationMinutes')) {
    $range = $Forecast.$name
    if ($null -eq $range) { return $false }
    foreach ($bound in @('low', 'high')) {
      $value = $range.$bound
      if ($value -isnot [ValueType] -or $value -is [bool]) { return $false }
      $number = [double]$value
      if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or $number -gt 1000000) { return $false }
    }
    if ($range.low -gt $range.high) { return $false }
  }
  if ($Forecast.coreMinutes.high -gt $Forecast.mandatoryMinutes.high -or $Forecast.coreMinutes.low -gt $Forecast.mandatoryMinutes.low) { return $false }
  if ($Forecast.confidence -notin @('low', 'medium', 'high') -or -not ([string]$Forecast.basis).Trim()) { return $false }
  if ($Forecast.riskMinutes -isnot [ValueType] -or $Forecast.riskMinutes -is [bool] -or
      [double]::IsNaN([double]$Forecast.riskMinutes) -or [double]::IsInfinity([double]$Forecast.riskMinutes) -or
      $Forecast.riskMinutes -lt 0 -or $Forecast.riskMinutes -gt 1000000) { return $false }
  if ($Forecast.remainingIterations -isnot [ValueType] -or $Forecast.remainingIterations -is [bool] -or
      $Forecast.remainingIterations -lt 0 -or $Forecast.remainingIterations -gt 1000000 -or
      [double]$Forecast.remainingIterations -ne [Math]::Floor([double]$Forecast.remainingIterations)) { return $false }
  if ($null -ne $Forecast.polish) {
    $p = $Forecast.polish
    if ([string]$p.id -notmatch '^Q[0-9]+$' -or -not $p.scopeReference -or -not $p.value -or -not $p.stopCondition) { return $false }
    if ($p.minutes -isnot [ValueType] -or $p.minutes -is [bool] -or [double]::IsNaN([double]$p.minutes) -or
        [double]::IsInfinity([double]$p.minutes) -or $p.minutes -le 0 -or $p.minutes -gt 1000000) { return $false }
  }
  return $true
}

function Get-AdaptiveDecision([object]$Config, [object]$State) {
  $available = (Get-EffectiveSeconds $Config $State) / 60.0
  $slots = [Math]::Max(0, [int]$Config.maxIterations - [int]$State.iterationsStarted)
  # Minimum future phase starts, including the pending/current phase as appropriate.
  $phaseSlots = @{ freeze = 4; build = 3; evidence = 2; verify = 1; fix = 2 }
  $minimumSlots = $phaseSlots[[string]$State.phase]
  if (-not $minimumSlots) { $minimumSlots = 1 }
  if ($State.currentIterationActive) { $slots++ }
  $decision = [ordered]@{
    stage = 'focus'; reason = 'No reliable work forecast yet; estimate remaining work before optional quality work.'
    availableMinutes = [Math]::Round($available, 2); requiredLowMinutes = $null; requiredHighMinutes = $null
    coreHighMinutes = $null; reserveMinutes = $null; slackMinutes = $null
    confidence = 'unknown'; forecastStatus = $State.forecastStatus; polishMinutes = 0
    requiredIterations = $minimumSlots; calibration = $State.forecastCalibration
  }
  if ($available -le 0 -or $slots -lt 1) {
    $decision.stage = 'last-call'; $decision.reason = 'No execution time or iteration starts remain.'
    return [pscustomobject]$decision
  }
  $f = $State.forecast
  $age = [Math]::Max(0.0, ([double]$State.accumulatedActiveSeconds - [double]$State.forecastAtActiveSeconds) / 60.0)
  $stale = $false
  if (Test-WorkForecast $f) { $stale = $age -gt [Math]::Max(1, $f.mandatoryMinutes.high + $f.verificationMinutes.high + $f.riskMinutes) }
  if (-not (Test-WorkForecast $f) -or $stale -or $State.forecastStatus -ne 'valid') {
    if ($stale) { $decision.forecastStatus = 'stale'; $decision.reason = 'Forecast aged beyond its completion range; re-estimate instead of assuming progress.' }
    # Absolute fallback check reserve, never a fraction of the original budget.
    if ($available -lt 1 -or $slots -lt $minimumSlots) {
      $decision.stage = 'last-call'; $decision.reason = 'No reliable forecast and insufficient capacity for the minimum proof path; preserve and report gaps.'
    }
    return [pscustomobject]$decision
  }
  $factor = [Math]::Max(1.0, [double]$State.forecastCalibration)
  $checkFloor = 1.0
  $checkSamples = @($State.iterationHistory | Where-Object { $_.phase -in @('evidence', 'verify', 'fix') })
  if ($checkSamples.Count) { $checkFloor = [Math]::Max($checkFloor, ($checkSamples | Measure-Object activeSeconds -Maximum).Maximum / 60.0) }
  $checks = [Math]::Max($checkFloor, [double]$f.verificationMinutes.high * $factor)
  $uncertainty = ($f.mandatoryMinutes.high - $f.mandatoryMinutes.low) + ($f.verificationMinutes.high - $f.verificationMinutes.low)
  $risk = [Math]::Max([double]$f.riskMinutes, $uncertainty)
  $risk = [Math]::Max($risk, [int]$State.consecutiveFailures * $checkFloor)
  if ($f.confidence -eq 'low') { $risk = [Math]::Max($risk, $checks) }
  $low = [double]$f.mandatoryMinutes.low + [double]$f.verificationMinutes.low
  $high = [double]$f.mandatoryMinutes.high * $factor + $checks + $risk
  $core = [double]$f.coreMinutes.high * $factor + $checks + $risk
  $requiredSlots = [Math]::Max($minimumSlots, [int]$f.remainingIterations)
  $decision.requiredIterations = $requiredSlots
  $decision.requiredLowMinutes = [Math]::Round($low, 2)
  $decision.requiredHighMinutes = [Math]::Round($high, 2)
  $decision.coreHighMinutes = [Math]::Round($core, 2)
  $decision.reserveMinutes = [Math]::Round($checks + $risk, 2)
  $decision.slackMinutes = [Math]::Round($available - $high, 2)
  $decision.confidence = $f.confidence
  if ($available -lt $core -or $slots -lt $minimumSlots) {
    $decision.stage = 'last-call'; $decision.reason = 'A usable core plus critical checks no longer fits the conservative time/iteration estimate.'
  } elseif ($available -lt $low -or $slots -lt $requiredSlots) {
    $decision.stage = 'ship'; $decision.reason = 'Full delivery is unlikely to fit; prioritize a usable core and report every mandatory gap.'
  } elseif ($available -lt $high -or $f.confidence -eq 'low') {
    $decision.stage = 'focus'; $decision.reason = 'Full delivery is at risk or uncertain; simplify implementation and close mandatory gaps.'
  } else {
    $decision.stage = 'craft'; $decision.reason = 'Full mandatory delivery, checks and risk reserve fit the current estimate.'
    $p = $f.polish
    if ($p -and $State.phase -eq 'build' -and $State.implementationReady -and $f.mandatoryMinutes.high -eq 0 -and
        @($State.polishAttempts).Count -eq 0 -and $slots -ge ($requiredSlots + 1) -and
        ($p.minutes * $factor) -le ([double]$Config.iterationTimeoutSeconds / 60.0) -and $available -ge ($high + $p.minutes * $factor)) {
      # Match an explicitly frozen quality-opportunity line, not an arbitrary worker permission flag.
      $specPath = Join-Path $Config.repoRoot ".agent/tasks/$($Config.taskId)/spec.md"
      $scopeLine = "- $($p.id): $($p.scopeReference)"
      if ((Test-Path -LiteralPath $specPath) -and @(Get-Content -LiteralPath $specPath -Encoding utf8) -ccontains $scopeLine) {
        $decision.stage = 'polish'; $decision.polishMinutes = [Math]::Round($p.minutes * $factor, 2)
        $decision.reason = "Mandatory implementation is ready; frozen $($p.id) and revalidation fit, with a single bounded polish attempt."
      }
    }
  }
  return [pscustomobject]$decision
}

function Get-PlanningDecision([object]$Config, [object]$State) {
  $decision = Get-AdaptiveDecision $Config $State
  $ranks = @{ 'last-call' = 0; ship = 1; focus = 2; craft = 3; polish = 4 }
  if ($ranks[$decision.stage] -gt $ranks[[string]$State.selectedStrategy] -and
      ($State.promotionCandidate -ne $decision.stage -or $State.promotionSamples -lt 2) -and
      -not ($decision.stage -eq 'polish' -and $State.feasibleSamples -ge 2)) {
    # Never keep polish if its feasibility disappears. Promote only on two fresh forecasts.
    $decision.stage = $State.selectedStrategy
    $decision.polishMinutes = 0
    $decision.reason = 'Awaiting two consecutive fresh feasible forecasts before upgrading the strategy. ' + $decision.reason
  }
  return $decision
}

function Receive-WorkForecast([object]$State, [object]$Config, [object]$Forecast, [bool]$TrustedResult) {
  if (-not $TrustedResult -or -not (Test-WorkForecast $Forecast)) {
    $State.forecastStatus = if ($null -eq $Forecast) { 'missing' } else { 'invalid' }
    $State.forecast = $null
    $State.promotionCandidate = ''; $State.promotionSamples = 0; $State.feasibleSamples = 0
    $State.selectedStrategy = (Get-AdaptiveDecision $Config $State).stage
    return
  }
  $old = $State.forecast
  if ((Test-WorkForecast $old) -and $State.forecastStatus -eq 'valid' -and $State.iterationStrategy -ne 'polish') {
    $previousHigh = $old.mandatoryMinutes.high + $old.verificationMinutes.high + $old.riskMinutes
    $currentHigh = $Forecast.mandatoryMinutes.high + $Forecast.verificationMinutes.high + $Forecast.riskMinutes
    $spent = [Math]::Max(0.0, ([double]$State.accumulatedActiveSeconds - [double]$State.forecastAtActiveSeconds) / 60.0)
    if ($previousHigh -gt 0 -and ($spent + $currentHigh) -gt $previousHigh) {
      $ratio = [Math]::Min(3.0, ($spent + $currentHigh) / $previousHigh)
      $State.forecastCalibration = [Math]::Min(3.0, [Math]::Max([double]$State.forecastCalibration, $ratio))
    }
  }
  $State.forecast = $Forecast; $State.forecastStatus = 'valid'
  $State.forecastAtActiveSeconds = $State.accumulatedActiveSeconds
  $State.forecastRevision = [int]$State.forecastRevision + 1
  $candidate = (Get-AdaptiveDecision $Config $State).stage
  if ($candidate -in @('craft', 'polish')) { $State.feasibleSamples++ } else { $State.feasibleSamples = 0 }
  if ($State.promotionCandidate -eq $candidate) { $State.promotionSamples++ }
  else { $State.promotionCandidate = $candidate; $State.promotionSamples = 1 }
  $State.selectedStrategy = (Get-PlanningDecision $Config $State).stage
}

function Close-StrategyInterval([object]$State, [string]$AtUtc, [string]$EndReason) {
  if (@($State.strategyHistory).Count -gt 0) {
    $last = $State.strategyHistory[-1]
    if (-not $last.endedAtUtc) {
      if (-not $AtUtc -or (ConvertTo-DateTimeOffsetValue $AtUtc) -lt (ConvertTo-DateTimeOffsetValue $last.startedAtUtc)) { $AtUtc = $last.startedAtUtc }
      $last.endedAtUtc = $AtUtc; $last.endReason = $EndReason
    }
  }
}

function Open-StrategyInterval([object]$State, [string]$Stage, [object]$Decision, [string]$StartedAtUtc = '') {
  $now = if ($StartedAtUtc) { $StartedAtUtc } else { Get-UtcNowIso }
  Close-StrategyInterval $State $now 'next-interval'
  if (-not $State.historyStartedAtUtc) {
    $State.historyStartedAtUtc = $now
    $State.historyBaselineActiveSeconds = $State.accumulatedActiveSeconds
  }
  $State.strategyHistory = @($State.strategyHistory) + @([pscustomobject]@{
    startedAtUtc = $now; endedAtUtc = $null; endReason = $null
    stage = $Stage; phase = $State.phase; iteration = $State.activeIteration
    activeSeconds = 0.0; reason = $Decision.reason; forecastRevision = $State.forecastRevision
    decision = $Decision
  })
}

function Get-BudgetAssessment([object]$State, [object]$Config) {
  $totals = [ordered]@{}
  foreach ($interval in @($State.strategyHistory)) {
    if (-not $totals.Contains($interval.stage)) { $totals[$interval.stage] = 0.0 }
    $totals[$interval.stage] += [double]$interval.activeSeconds
  }
  $decision = Get-AdaptiveDecision $Config $State
  $assessment = 'undetermined'
  if ($State.completed) { $assessment = 'completed-within-budget' }
  elseif ($State.blocked) { $assessment = 'blocked-not-a-budget-conclusion' }
  elseif ($State.stopReason -in @('active-budget-exhausted', 'absolute-deadline-reached')) { $assessment = 'time-exhausted-with-gaps' }
  elseif ($State.stopReason -eq 'max-iterations-exhausted') { $assessment = 'iteration-capacity-exhausted' }
  elseif ($State.stopReason -eq 'user-requested') { $assessment = 'stopped-by-user' }
  elseif ($decision.forecastStatus -eq 'valid') { $assessment = if ($decision.slackMinutes -ge 0) { 'forecast-fits' } else { 'forecast-at-risk' } }
  return [pscustomobject]@{
    assessment = $assessment; activeSecondsByStrategy = [pscustomobject]$totals
    unrecordedActiveSeconds = $State.historyBaselineActiveSeconds
    unusedActiveSeconds = $State.remainingActiveSeconds
    forecastSlackMinutes = $decision.slackMinutes
    caveat = 'Unused time is headroom, not proof of waste. Exhaustion with gaps does not distinguish low budget from blockers, retries or forecast error; inspect intervals and iteration outcomes.'
  }
}
