# Durable Runtime

## Scope

The durable runtime is an external Windows PowerShell supervisor for Codex CLI. It is deliberately separate from the proof-loop task artifacts and from the Codex worker's semantic decisions.

It provides manual recovery, not an operating-system service. It does not register Scheduled Tasks, startup entries, or recurring jobs.

## State ownership

The supervisor exclusively owns `.agent/durable-loop/<TASK_ID>/config.json`, `runtime.json`, and `logs/`. Workers receive an explicit instruction not to edit that directory.

`config.json` is immutable after initialization unless an operator edits it while the loop is stopped. It contains:

- repository and task identity
- active-time budget
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

## Phase transitions

```text
freeze -> build -> evidence -> verify
                              | PASS -> complete
                              | FAIL/UNKNOWN -> fix -> verify
```

Each worker must return a schema-constrained result with its phase, status, and summary. A `completed` result is accepted only when the expected phase artifact is ready. Final completion additionally requires a `PASS` verdict and successful proof-package structural validation.

## Failure semantics

- Worker timeout or active-budget exhaustion: terminate the worker process tree and retry or stop according to remaining limits.
- Invalid/missing structured result: retry the same phase and increment consecutive failures.
- Missing phase artifact: retry the same phase and increment consecutive failures.
- Explicit worker blocker: stop and require operator resolution plus `start -Force`.
- Repeated failures: stop after `maxConsecutiveFailures` and require inspection.
- Codex CLI temporarily missing: keep heartbeat and retry resolution without consuming an iteration.
- Safe stop: let the current child finish, checkpoint it, and do not start another child.

## Trust boundary

The supervisor enforces process and state invariants but does not decide whether product behavior is correct. The fresh verifier owns semantic acceptance. Conversely, workers cannot declare themselves exempt from timeout, budget, phase, or artifact requirements.
