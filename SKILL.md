---
name: deadline-carl
description: Run non-trivial repository work through a deadline-aware, recoverable Codex CLI supervisor with time-pressure planning, disk checkpoints, explicit budget extensions, and a repo-local spec/evidence/fresh-verifier proof loop. Use when the user explicitly requests an unattended or manually recoverable development loop on Windows. Do not use for one-shot edits or recurring scheduled jobs.
license: Apache-2.0
metadata:
  version: "3.2.0"
---

# Deadline-Carl

Deadline-Carl is the worker who watches the clock without lying about the work. Use this skill to run a bounded repository task through two cooperating layers:

1. The proof protocol freezes a spec, builds, records criterion-level evidence, runs a fresh independent verifier, and applies minimal fixes until every acceptance criterion passes.
2. The external PowerShell supervisor starts fresh `codex exec` workers, gives each worker current deadline pressure, writes heartbeat and checkpoint state, enforces time and iteration budgets, terminates timed-out workers, and resumes after a manual `start` when the supervisor was interrupted.

The frozen contract also produces `plan.json`, an immutable denominator of mandatory work items, plus `progress.json`, the builder's implementation state. Status reports implementation, fresh verification, and acceptance progress separately; iteration count remains a safety budget rather than a completion percentage.

The supervisor is deterministic infrastructure. Codex workers make semantic decisions. Do not ask a worker to manage its own PID, heartbeat, runtime budget, or recovery state.

## Delivery modes

`deadline-aware` is the default. Every iteration receives total and remaining active time, remaining percentage, iteration timeout, remaining iteration starts, and one deterministic planning stage:

- `craft` at 50% or more remaining: complete the requested scope with justified quality work.
- `focus` at 20-50% remaining: stop speculative expansion and close mandatory criteria plus high-risk integration gaps.
- `ship` at 5-20% remaining: stop optional polish, finish the smallest usable end-to-end core, test it, and checkpoint partial work.
- `last-call` below 5% remaining: stabilize, run critical smoke checks, and write `deadline-report.md` with delivered core, mandatory gaps, actual checks, and a defensible extension estimate.

Time pressure changes execution order, never PASS semantics. User-mandated criteria remain mandatory, and incomplete work must be reported as partial rather than disguised as PASS.

Use `proof-first` only when the user wants the previous budget-agnostic behavior. It retains the same hard limits but does not ask workers to change priorities as the deadline approaches.

## Safety boundary

- Never start a background loop unless the user explicitly asks to run it.
- Initialization changes the target repository by creating `.agent/tasks/<TASK_ID>/`, `.agent/durable-loop/<TASK_ID>/`, `.agent/deadline-carl-scratch/<TASK_ID>/`, `.codex/agents/`, a managed block in `AGENTS.md`, and an idempotent local-state block in `.gitignore`.
- This skill never registers Windows Scheduled Tasks, services, startup entries, or recurring automations.
- The default worker uses `codex exec --approve-for-me`, not unrestricted YOLO mode.
- Never reset, clean, checkout, or discard existing worktree changes.
- A safe stop lets the active iteration finish but prevents another iteration from starting.
- `start -Force` only clears a recorded loop blocker. It does not overwrite proof artifacts or reset Git state.
- Budget extension is explicit, additive, and allowed only while the supervisor is stopped.

## Commands

All paths below are relative to this installed skill directory. Run commands from any location inside the target Git repository, or provide `-RepoRoot` explicitly.

### Doctor

Check Git, Python, Codex CLI, authentication, and package files without starting work:

```powershell
& scripts/durable_loop.ps1 doctor -RepoRoot D:\path\to\repo
```

### Initialize

Choose a stable task ID and seed the original request:

```powershell
& scripts/durable_loop.ps1 init `
  -RepoRoot D:\path\to\repo `
  -TaskId feature-auth-hardening `
  -TaskText "Implement auth hardening and prove every acceptance criterion."
```

Useful bounded-run options:

```powershell
-ActiveBudgetMinutes 720
-IterationTimeoutMinutes 25
-MaxIterations 30
-RetryDelaySeconds 20
-CliUnavailableTimeoutMinutes 30
-MaxConsecutiveFailures 6
-Model gpt-5.6-sol
-DeliveryMode deadline-aware
```

Initialization is idempotent and preserves existing task files. It invokes `scripts/task_loop.py init` with Codex project agents and the repo-root `AGENTS.md` managed block.

### Start or recover

Start the hidden external supervisor:

```powershell
& scripts/durable_loop.ps1 start -RepoRoot D:\path\to\repo -TaskId feature-auth-hardening
```

If Codex Desktop updates but the supervisor survives, it waits for `codex` to become available and resolves the executable again before every new iteration. If the supervisor exits, run the same `start` command manually. Stale supervisor state is cleared, a still-running child is adopted, and the current proof phase resumes from disk.

If a genuine blocker was recorded and has been resolved:

```powershell
& scripts/durable_loop.ps1 start -RepoRoot D:\path\to\repo -TaskId feature-auth-hardening -Force
```

### Extend a stopped loop

`start` never replenishes time. To add a reviewed recovery budget, stop the loop and extend it explicitly:

```powershell
& scripts/durable_loop.ps1 extend `
  -RepoRoot D:\path\to\repo `
  -TaskId feature-auth-hardening `
  -AdditionalBudgetMinutes 720
```

The extension preserves accumulated active time, proof artifacts, phase, logs, and Git state. It records the added seconds in configuration and status output.

Extending time does not add iteration starts. If `maxIterations` is also exhausted, inspect the failure pattern before choosing a new bounded task configuration.

### Status and checkpoint

```powershell
& scripts/durable_loop.ps1 status -RepoRoot D:\path\to\repo -TaskId feature-auth-hardening
& scripts/durable_loop.ps1 checkpoint -RepoRoot D:\path\to\repo -TaskId feature-auth-hardening
```

Do not poll status continuously. Read it when the user asks, after an interruption, or when diagnosing a stale heartbeat.

### Direct progress questions

When the user asks "what is the current progress?", "how far along is it?", "what remains?", or an equivalent question, read fresh status before answering. Use `durable_loop.ps1 status` for a supervised task; do not infer current progress only from chat history or the latest worker summary.

Reply in the user's language as a concise human-readable status, not raw JSON unless the user requests machine-readable output. Present these fields in order:

1. task ID and overall state: `completed`, `blocked`, `running`, or stopped but incomplete
2. current proof phase and its plain-language meaning
3. implementation, fresh-verification, and acceptance progress as separate exact counts
4. remaining active-time budget, remaining percentage, and deadline stage
5. latest concrete activity or checkpoint
6. current blocker, stop reason, or non-PASS acceptance gaps; say none when there is no known blocker
7. the next expected action

Use only values supported by the current status and proof artifacts. Say that a value is not available when its denominator or artifact does not exist. Never turn `iterationBudgetDisplay` into task completion; mention it only when execution capacity is relevant and label it as iteration capacity. Never report overall completion merely because one progress bar reached its denominator. Overall completion still requires `completed: true`, a fresh-verifier `PASS`, and successful proof validation.

Use the response template and phase/state mappings in `references/COMMANDS.md` when handling a direct progress question.

### Safe stop

```powershell
& scripts/durable_loop.ps1 stop -RepoRoot D:\path\to\repo -TaskId feature-auth-hardening
```

The active worker may finish. No new worker starts afterward.

## Durable state

Proof artifacts remain compatible with the upstream workflow:

```text
.agent/tasks/<TASK_ID>/
  spec.md
  plan.json
  progress.json
  evidence.md
  evidence.json
  verdict.json
  problems.md
  raw/
```

Supervisor-owned state is separate:

```text
.agent/durable-loop/<TASK_ID>/
  config.json
  runtime.json
  logs/
```

Transient Worker output is isolated from formal evidence:

```text
.agent/deadline-carl-scratch/<TASK_ID>/
  iteration-<NNN>-<PHASE>/
```

The supervisor and scratch directories are local state: `init` ignores `/.agent/durable-loop/`, `/.agent/deadline-carl-scratch/`, and the temporary task initialization sentinel. Keep the proof bundle under `.agent/tasks/` available for review; do not ignore the entire `.agent/` tree.

Workers must not edit `.agent/durable-loop/`. `runtime.json` is atomically replaced and contains the phase, active-time usage, heartbeat, supervisor/child identity, current log paths, failures, and completion state.

Status output also exposes `deliveryMode`, `deadlineStage`, total and extended budget, remaining percentage, and a terminal `stopReason` such as `completed`, `active-budget-exhausted`, or `max-iterations-exhausted`.

It additionally exposes:

- `progressDisplay.implementation`, such as `8/26`, from frozen work items marked implemented
- `progressDisplay.verification`, from work items whose mapped criteria passed the fresh verifier
- `progressDisplay.acceptance`, such as `1/12`, from criterion-level evidence
- `iterationBudgetDisplay`, such as `15/120`, explicitly labeled as capacity rather than progress
- `gitHygiene`, including ignore readiness, tracked local-state files, broad rules that hide proof artifacts, and scoped managed-path status
- `lastWriteBoundaryStatus` and `lastWriteBoundaryViolations`, showing whether the previous Worker changed task artifacts owned by another phase

## Proof phases

The supervisor runs one fresh Codex process per phase:

1. `freeze`: complete `spec.md` with explicit `AC1`, `AC2`, ... criteria, a stable work-item table, constraints, non-goals, and verification plan. The supervisor freezes `plan.json` and initializes `progress.json`. Do not edit production code.
2. `build`: implement only the frozen contract and run relevant checks. Return `progressed` after productive partial work and remain in build. The phase advances only when every frozen work item is implemented.
3. `evidence`: stop changing production code, write transient check output to the supplied scratch directory, then deliberately promote selected criterion-level proof into the evidence bundle and `raw/`.
4. `verify`: use a fresh process to rerun checks into scratch and replace both `verdict.json` and `problems.md` without changing production code, evidence, or `raw/`. A PASS writes a zero-problem report; FAIL or UNKNOWN writes detailed findings. Never preserve a stale problems report from an earlier pass.
5. `fix`: reconfirm verifier findings, apply the smallest safe changes, update work-item progress, and refresh evidence. Partial repair returns `progressed`; a fresh verifier runs only after the build and evidence gates are both ready.

Before every Worker starts, the supervisor records hashes for the formal task bundle. After it exits, the supervisor enforces the phase write set: `freeze` may change `spec.md`; `build` may change `progress.json`; `evidence` may change evidence files and `raw/`; `verify` may change only verdict and problems; `fix` may change progress and evidence. `deadline-report.md` is allowed in every phase. A cross-phase change blocks the loop with exact file diagnostics and is never reverted automatically.

Overall completion requires all frozen work items implemented, a `PASS` verdict, and successful structural validation from `scripts/task_loop.py validate`. The PowerShell supervisor delegates artifact validation to that Python validator so schema rules have one executable source of truth.

Frozen acceptance criteria may use either list form (`- AC1: ...`) or Markdown heading form (`### AC1 — ...`). The supervisor recognizes both; changing presentation must not cause a completed freeze phase to repeat.

Read the upstream proof details only when needed:

- `references/COMMANDS.md` for phase prompts and responsibilities
- `references/SUBAGENTS.md` for project-scoped Codex agent behavior
- `references/SCHEMAS.md` for evidence and verdict contracts
- `references/REFERENCE.md` for recovery and evidence principles
- `references/DURABLE_RUNTIME.md` for supervisor state and failure semantics

## Report back

After initialization or start, report:

- repository path
- task ID
- whether the supervisor is running
- current phase
- remaining active-time budget
- exact status and stop commands

Do not claim the repository task is complete merely because the supervisor started. Completion means `runtime.json` reports `completed: true`, `verdict.json` reports `PASS`, and proof validation succeeds.

## Package validation

Before distributing a changed copy of this skill, run:

```powershell
python scripts/verify_package.py
pwsh -NoProfile -File scripts/test_durable_loop.ps1
```

Also validate the Skill structure with Codex's bundled `quick_validate.py` when available.
