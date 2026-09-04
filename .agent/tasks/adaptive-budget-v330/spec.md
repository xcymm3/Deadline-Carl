# Task Spec: adaptive-budget-v330

## Original task statement
Replace percentage-based deadline strategies with evidence-informed remaining-work estimates, bounded in-scope polish, and a time history that explains budget adequacy. Update the package, test it, push related changes, and synchronize the installed copy.

## Acceptance criteria
- AC1: Five planning strategies use remaining-work ranges, check/repair reserve, confidence, iteration capacity, and observed forecast error rather than fixed remaining-budget percentages. Missing/invalid estimates degrade safely; promotion needs stable forecasts.
- AC2: Optional polish is bounded, only available in build for a frozen quality opportunity after mandatory implementation, and cannot bypass fresh evidence/verifier gates. Incomplete mandatory scope never becomes PASS.
- AC3: Optional timezone-explicit absolute deadlines constrain effective time, starts and running workers; extending active budget does not move the absolute deadline.
- AC4: Supervisor persists strategy/phase intervals with UTC boundaries, active duration and reasons, iteration forecasts/observations and budget assessment; pauses and unknown legacy history are not fabricated, and status reads do not create history entries.
- AC5: Tests cover strategy decisions, bad/stale forecasts, upgrades/downgrades, time accounting/recovery, deadlines, bounded polish and existing verifier/write-boundary behavior. Package validation passes.
- AC6: Versioned skill, schema, prompts, runtime documentation and README agree; final installation matches the verified source and remote commit.

## Work items
| Item | Description | Acceptance criteria |
| --- | --- | --- |
| WI-001 | Implement adaptive forecasting and bounded polish | AC1, AC2 |
| WI-002 | Enforce absolute deadlines and record strategy history | AC3, AC4 |
| WI-003 | Regression tests and package documentation | AC5, AC6 |

## Constraints
- Preserve mandatory acceptance criteria, user changes and Git history.
- Forecasts are uncertain worker estimates, not proof of completion.
- No background development loop is started for this implementation task.
- Keep current proof phases and phase-specific artifact write ownership.

## Non-goals
- No unrestricted scope expansion, automatic budget extension or claim of perfect quality.
- No retroactive reconstruction of unrecorded strategy history.

## Verification plan
- Run policy unit tests, package smoke validation, durable supervisor recovery regression and skill quick validation.
- Fresh verification pass reruns checks independently of builder assertions, then replaces verdict.json and problems.md.
- Compare installed file hashes and remote HEAD after delivery.
