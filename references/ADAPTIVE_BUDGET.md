# Adaptive budget and time history (v3.3)

## Forecast contract

Each Worker returns `forecast` in its result JSON, never by editing supervisor state. It is null when a defensible forecast is unavailable, otherwise:

```json
{
  "mandatoryMinutes": {"low": 30, "high": 50},
  "coreMinutes": {"low": 5, "high": 10},
  "verificationMinutes": {"low": 5, "high": 15},
  "riskMinutes": 10,
  "remainingIterations": 4,
  "confidence": "medium",
  "basis": "WI-003 integration and AC2 regression remain; last check took 5 minutes; API behavior is uncertain",
  "polish": null
}
```

Estimate work remaining AFTER the iteration. Core is a subset of mandatory implementation, not an additional amount. Verification includes remaining evidence, integration, independent verification and likely repairs. Ranges must be finite, nonnegative and ordered. Iteration forecasts cover future starts. Base estimates on dependencies, complexity, unknowns, failed checks, observed work and estimate errors, not item-count velocity. Estimates are uncertain and do not establish acceptance.

## Deterministic decisions

Effective minutes are the minimum of remaining active budget and time until optional `deadlineUtc`. Capacity also respects minimum proof-phase starts (`freeze`: 4, `build`: 3, `evidence`: 2, `verify`: 1, `fix`: 2), not just the Worker's iteration estimate.

The supervisor uses a conservative calibration multiplier (1–3). When elapsed time plus the new remaining estimate exceeds the previous estimate, it raises this multiplier; optimistic claims do not reduce it. Optional polish time is excluded from this comparison. This is an overrun indicator, not a statistically calibrated probability.

- Check reserve is at least one minute and at least the longest observed evidence/verify/fix iteration, or the calibrated verification high estimate when larger.
- Additional risk reserve is at least the forecast risk, combined range width, and a failure-based check allowance. Low confidence reserves at least another check allowance.
- Full low estimate = mandatory low + verification low.
- Full high estimate = calibrated mandatory high + check reserve + risk reserve.
- Core high estimate = calibrated core high + the same check/risk reserve. This deliberately reserves full checks even for partial delivery.

If the core or minimum proof path cannot fit, select `last-call`. If core fits but full low estimate or forecast iteration capacity does not, select `ship`. If full high estimate does not fit, or confidence is low, select `focus`; otherwise select `craft`. Only an eligible frozen quality opportunity can further promote to `polish`.

Promotion normally requires two consecutive fresh forecasts supporting the target. Two consecutive full-delivery-feasible forecasts can support polish once implementation is ready. Polling never adds promotion samples. Downgrades apply immediately to planning for the next Worker. A running Worker retains its dispatched strategy; the supervisor does not pretend to change an already-issued prompt. Hard deadlines remain enforced while it runs.

Missing/invalid estimates use `focus`, or `last-call` when less than one effective minute/minimum phase capacity remains. Forecasts older in active time than their upper completion range (minimum one minute) are stale. Failed, timed-out or write-violating results invalidate forecasts. A legacy result without the new field can still satisfy proof gates, but cannot grant polish.

## Bounded polish

Freeze an exact line under `## Quality opportunities`, for example:

```text
- Q1: Improve enemy hit feedback while preserving simple geometry
```

A candidate contains `id` (`Q1`), `scopeReference` (the exact description), conservative `minutes` including incremental verification, `value`, and `stopCondition`. The supervisor matches the frozen line and checks implementation readiness, confidence, stable feasibility, time/iteration reserve and the per-iteration limit. At most one optional polish attempt is permitted per task in v3.3; this deliberately conservative cap prevents an open-ended perfection loop.

The build Worker returns completed when mandatory implementation is ready. The supervisor may retain build once for eligible polish before evidence; Workers must not manufacture progressed iterations to await permission. No improvement is required just because time remains. Evidence and verify cannot edit production code. Polish requires subsequent fresh evidence and verifier PASS. If it fails or times out, stabilize within normal build/fix work; never discard user code automatically or treat old verification as current.

## Absolute deadline

`init -DeadlineUtc '2026-09-05T18:00:00+08:00'` stores UTC. Explicit timezone is required; past deadlines are rejected. Without this optional setting, active-time-only behavior remains. Pauses do not consume active time but do consume wall time. An elapsed deadline prevents starts and terminates running children; `extend` only increases active time. Moving the absolute deadline requires an explicit user decision and a stopped-loop configuration change.

## History and interpretation

Supervisor-owned `runtime.json` persists:

- `strategyHistory`: UTC start/end, end reason, phase, iteration, dispatched strategy, charged active seconds, decision reason, estimate range/reserve and forecast revision. `waiting` is supervisor overhead/retry/recovery, not AI quality work. Interruption closes at the last observed heartbeat; recovery opens another interval.
- `iterationHistory`: start/end, active duration, strategy, phase, result/exit status, write-boundary outcome and before/after estimates.
- `budgetEvents`: explicit additive active-budget extensions and when they occurred.
- `budgetAssessment`: per-strategy active totals, unrecorded pre-migration/boundary-gap time, remaining active time, forecast slack and a qualified conclusion. Ticks crossing strategy boundaries are split by actual interval overlap; totals plus unrecorded active time reconcile with the charged budget.

`history -RepoRoot <repo> -TaskId <id>` exposes the full persisted history. `status` includes the last 10 intervals and 5 iterations, full-history counts, and totals; use `history` when these counts exceed the returned subset. Reading history never increases forecast confidence or invents intervals. Standard stale-supervisor recovery can close an interrupted interval at its last observation. Data is heartbeat/checkpoint based, not continuous surveillance. UTC spans may include suspension; use charged `activeSeconds`, not end minus start, for allocation. Existing unrecorded history is unknown, never reconstructed. Runtime history stays locally ignored.

For a time-allocation question, render a compact table in the user's timezone: interval, strategy/phase, active duration and reason. Include waits separately and explain whether the task completed, exhausted time/iterations, was stopped or blocked. Example (illustrative, not measured):

| Local interval | Strategy | Active time | Reason |
| --- | --- | --- | --- |
| 10:00–10:12 | focus / build | 12 min | Initial estimate uncertain |
| 10:12–10:40 | craft / build | 28 min | Full work and checks fit |
| 10:40–10:45 | polish / build | 5 min | Frozen feedback improvement fits |

Unused time is observed headroom, not proof of excessive budget; it may be a safety margin. Exhaustion with gaps does not prove initial allocation was too small: inspect errors, blockers, waits, polish cost and forecast calibration. Completion cost informs similar future tasks, not a precise recommendation for a different project. Show missing estimates as unavailable, not zero.
