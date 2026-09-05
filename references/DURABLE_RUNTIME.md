# Durable Runtime

## Scope

The durable runtime is an external Windows PowerShell supervisor for Codex CLI. It is deliberately separate from the proof-loop task artifacts and from the Codex worker's semantic decisions.

It provides manual recovery, not an operating-system service. It does not register Scheduled Tasks, startup entries, or recurring jobs.

## State ownership

The supervisor exclusively owns `.agent/durable-loop/<TASK_ID>/config.json`, `runtime.json`, and `logs/`. Workers receive an explicit instruction not to edit that directory.

`init` idempotently adds a managed local-state block to the target repository's `.gitignore`. It excludes `.agent/durable-loop/`, `.agent/deadline-carl-scratch/`, and the temporary task initialization sentinel. Runtime state contains machine-specific paths, process identities, heartbeats, and logs, so it remains local while still supporting recovery on that machine. Proof artifacts under `.agent/tasks/` are separate and are not ignored by this rule.

`config.json` is immutable after initialization unless an operator edits it while the loop is stopped. It contains:

- repository and task identity
- active-time budget and optional absolute UTC deadline
- delivery mode and cumulative explicit budget extensions
- per-iteration timeout
- maximum iterations and consecutive failures
- heartbeat and retry intervals
- Codex CLI recovery window
- optional model and executable overrides

`runtime.json` is atomically replaced after every state transition and heartbeat. It contains:

- current proof phase
- supervisor and child PID plus process start time
- active iteration paths and timestamps
- accumulated and remaining active time
- stop, blocked, and completion state
- last exit code, summary, checkpoint, and failure count

Status joins runtime state with the frozen proof plan and reports separate implementation, fresh-verification, and acceptance bars. `iterationsStarted/maxIterations` remains an execution-capacity counter, not task completion.

Status also includes `gitHygiene`, `scratchDirectory`, `currentScratchDirectory`, `lastWriteBoundaryStatus`, `lastWriteBoundaryViolations`, `lastWriteBoundaryRecovery`, and bounded `writeBoundaryRecoveryHistory`. Git hygiene detects missing local-state ignores, broad rules that hide `.agent/tasks/`, and runtime or scratch files already present in the Git index. It reports these conditions but never changes the index.

## Scratch output and phase write sets

Every iteration receives a unique `.agent/deadline-carl-scratch/<TASK_ID>/iteration-<NNN>-<PHASE>/` directory through its prompt. `DEADLINE_CARL_SCRATCH_DIR` identifies it and `DEADLINE_CARL_OUTPUT_DIR` remains a compatibility alias. `DEADLINE_CARL_FORMAL_TASK_DIR` identifies the proof ledger, while `DEADLINE_CARL_ALLOWED_TASK_WRITES` is a JSON array for the current phase. Transient screenshots, traces, coverage, auxiliary plans, and test reports belong in scratch, preferably under `auxiliary/<skill>/`. The evidence or fix phase explicitly promotes only selected current proof into `.agent/tasks/<TASK_ID>/raw/`.

The supervisor hashes the formal task bundle before starting each Worker and checks it afterward. Allowed task-artifact writes are:

- `freeze`: `spec.md`
- `build`: `progress.json`
- `evidence`: `evidence.md`, `evidence.json`, and `raw/`
- `verify`: `verdict.json` and `problems.md`
- `fix`: `progress.json`, evidence files, and `raw/`
- every phase: `deadline-report.md`

The complete policy, including product-output classification, automatic quarantine, and operator repair, is in [Write boundaries](WRITE_BOUNDARIES.md).

If every violation is a newly created, disallowed file, the supervisor moves it into a unique per-iteration quarantine, writes an audit manifest, verifies the original task path is gone, counts the iteration as a failure, and retries the same phase. The recovered iteration is never accepted as phase completion and its forecast is not trusted. Repetition reaches `maxConsecutiveFailures` normally.

Modified, deleted, unsafe, or mixed violations block immediately. The supervisor never reverts source-code changes or protected proof artifacts. A stopped older loop with an eligible created-only blocker can use `repair-boundary`; it clears the blocker but does not start the loop.

## Recovery behavior

Running `start` performs these checks:

1. If the recorded supervisor PID and start time still identify a live process, it returns the existing status without starting another supervisor.
2. If the supervisor is stale, it clears only supervisor ownership. It preserves task files, runtime phase, logs, Git state, and any still-running Codex child.
3. The new supervisor adopts a live child and waits for its structured result.
4. If the child is gone, the supervisor evaluates its saved result and retries the same phase when no valid completion result exists.
5. Before every new iteration, the supervisor resolves `codex` again. A missing executable is treated as a recoverable update window until the configured CLI-unavailable timeout expires.

The runtime never resets or cleans the repository during recovery.

## Active-time accounting

Only time while the supervisor is running counts toward the active-time budget. Heartbeat updates cap each elapsed increment so a suspended process cannot consume a large amount of budget on wake. A stopped supervisor, powered-off machine, or manual recovery gap does not consume active time.

`start` never replenishes active time. The `extend` command adds a positive number of minutes only while the supervisor is stopped. It preserves accumulated time, phase, proof artifacts, logs, and Git state.

## Deadline-aware planning

The default `deadline-aware` mode compares fresh remaining-work ranges and verification/risk reserve with effective time and iteration capacity. It selects `polish`, `craft`, `focus`, `ship` or `last-call`; remaining percentage is display-only. See [Adaptive budget](ADAPTIVE_BUDGET.md) for exact decisions, estimate calibration, bounded quality work and UTC/active-time history.

Workers see the total and remaining active minutes, remaining percentage, per-iteration timeout, and remaining iteration starts. They use this context for planning but do not own or edit runtime state. Deadline stages change work ordering, not acceptance semantics. A required criterion remains required, and the fresh verifier remains the semantic completion authority. `proof-first` retains budget enforcement without deadline-driven priority guidance.

## Phase transitions

```text
freeze -> build --progressed--> build -> evidence -> verify
                                           | PASS -> complete
                                           | FAIL/UNKNOWN -> fix --progressed--> fix -> verify
```

Each worker must return a schema-constrained result with its phase, status, summary and nullable remaining-work forecast. A `completed` result is accepted only when the expected phase artifact is ready. Final completion additionally requires a `PASS` verdict and successful proof-package structural validation. Build completion can schedule one eligible polish iteration before evidence; it cannot skip verification.

`progressed` means an iteration made productive partial progress while the phase remains incomplete. It resets consecutive execution failures but never advances the phase. Build completion additionally requires every immutable work-plan item to be `implemented`; fix completion requires that gate plus current valid evidence.

## Failure semantics

- Worker timeout or active-budget exhaustion: terminate the worker process tree and retry or stop according to remaining limits.
- Invalid/missing structured result: retry the same phase and increment consecutive failures.
- Missing phase artifact: retry the same phase and increment consecutive failures.
- Explicit worker blocker: stop and require operator resolution plus `start -Force`.
- Created-only cross-phase task-artifact write: quarantine with a manifest, count a failure, and retry the same phase; block on repetition.
- Modified, deleted, unsafe, or mixed task-artifact write: block immediately with exact file diagnostics and require manual review.
- Repeated failures: stop after `maxConsecutiveFailures` and require inspection.
- Codex CLI temporarily missing: keep heartbeat and retry resolution without consuming an iteration.
- Safe stop: let the current child finish, checkpoint it, and do not start another child.
- Budget or iteration exhaustion: record a machine-readable `stopReason`; incomplete work remains partial even when a usable core was delivered.

## Trust boundary

The supervisor enforces process and state invariants but does not decide whether product behavior is correct. The fresh verifier owns semantic acceptance. Conversely, workers cannot declare themselves exempt from timeout, budget, phase, or artifact requirements.
