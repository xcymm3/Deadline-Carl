---
name: codex-durable-loop
description: Run non-trivial repository work through a recoverable Codex CLI supervisor with disk checkpoints, active-time budgets, iteration timeouts, heartbeat, and a repo-local spec/evidence/fresh-verifier proof loop. Use when the user explicitly requests an unattended or manually recoverable development loop on Windows. Do not use for one-shot edits or recurring scheduled jobs.
license: Apache-2.0
metadata:
  version: "2.0.0"
---

# Codex Durable Loop

Use this skill to run a bounded repository task through two cooperating layers:

1. The proof protocol freezes a spec, builds, records criterion-level evidence, runs a fresh independent verifier, and applies minimal fixes until every acceptance criterion passes.
2. The external PowerShell supervisor starts fresh `codex exec` workers, writes heartbeat and checkpoint state, enforces time and iteration budgets, terminates timed-out workers, and resumes after a manual `start` when the supervisor was interrupted.

The supervisor is deterministic infrastructure. Codex workers make semantic decisions. Do not ask a worker to manage its own PID, heartbeat, runtime budget, or recovery state.

## Safety boundary

- Never start a background loop unless the user explicitly asks to run it.
- Initialization changes the target repository by creating `.agent/tasks/<TASK_ID>/`, `.agent/durable-loop/<TASK_ID>/`, `.codex/agents/`, and a managed block in `AGENTS.md`.
- This skill never registers Windows Scheduled Tasks, services, startup entries, or recurring automations.
- The default worker uses `codex exec --approve-for-me`, not unrestricted YOLO mode.
- Never reset, clean, checkout, or discard existing worktree changes.
- A safe stop lets the active iteration finish but prevents another iteration from starting.
- `start -Force` only clears a recorded loop blocker. It does not overwrite proof artifacts or reset Git state.

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

### Status and checkpoint

```powershell
& scripts/durable_loop.ps1 status -RepoRoot D:\path\to\repo -TaskId feature-auth-hardening
& scripts/durable_loop.ps1 checkpoint -RepoRoot D:\path\to\repo -TaskId feature-auth-hardening
```

Do not poll status continuously. Read it when the user asks, after an interruption, or when diagnosing a stale heartbeat.

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

Workers must not edit `.agent/durable-loop/`. `runtime.json` is atomically replaced and contains the phase, active-time usage, heartbeat, supervisor/child identity, current log paths, failures, and completion state.

## Proof phases

The supervisor runs one fresh Codex process per phase:

1. `freeze`: complete `spec.md` with explicit `AC1`, `AC2`, ... criteria, constraints, non-goals, and verification plan. Do not edit production code.
2. `build`: implement only the frozen contract and run relevant checks.
3. `evidence`: stop changing production code and populate criterion-level proof plus raw outputs.
4. `verify`: use a fresh process to rerun checks and write the verdict without changing production code or evidence.
5. `fix`: reconfirm verifier findings, apply the smallest safe changes, refresh evidence, then return to a fresh verifier.

Overall completion requires a `PASS` verdict and successful structural validation from `scripts/task_loop.py validate`.

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
