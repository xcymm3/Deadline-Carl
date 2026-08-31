# Deadline-Carl

A directly installable Codex Skill for deadline-aware, proof-driven, manually recoverable repository work on Windows. Carl watches the clock, protects the usable core when time gets tight, and never calls incomplete work PASS.

It combines the spec/evidence/fresh-verifier workflow from [repo-task-proof-loop](https://github.com/DenisSergeevitch/repo-task-proof-loop) with an external PowerShell supervisor derived from the recovery approach used in `workstation-defense/loop`.

## Features

- Frozen task specification with explicit acceptance criteria
- Criterion-level evidence and a fresh verifier/fixer cycle
- Fresh non-interactive `codex exec` process for every proof phase
- Hidden PowerShell supervisor with PID identity checks
- Atomic checkpoint state and 10-second heartbeat
- Active-time, iteration, timeout, and failure budgets
- Deadline stages that shift workers from craft to focus, ship, and last-call behavior
- Honest `deadline-report.md` handoff when required work cannot fit the remaining budget
- Explicit additive budget extension while the supervisor is stopped
- Timed-out process-tree termination
- Manual restart from the current phase without discarding Git changes
- Adoption of a still-running Codex child after supervisor interruption
- Codex CLI re-resolution and retry during desktop update windows
- No Windows Scheduled Task, service, startup entry, or unrestricted YOLO mode

## Install

From this checkout:

```powershell
pwsh -NoProfile -File .\scripts\install_skill.ps1
```

Replace an existing installation while preserving a timestamped backup:

```powershell
pwsh -NoProfile -File .\scripts\install_skill.ps1 -Force
```

Restart Codex after installation. The default destination is `$CODEX_HOME\skills\deadline-carl`, or `$HOME\.codex\skills\deadline-carl` when `CODEX_HOME` is unset. `-Force` also moves a legacy `codex-durable-loop` installation to a timestamped backup before installing Deadline-Carl.

## Use

Invoke `$deadline-carl` in Codex, or run the packaged commands directly.

```powershell
$skill = Join-Path (${env:CODEX_HOME} ?? (Join-Path $HOME '.codex')) 'skills\deadline-carl'

& "$skill\scripts\durable_loop.ps1" doctor -RepoRoot D:\path\to\repo

& "$skill\scripts\durable_loop.ps1" init `
  -RepoRoot D:\path\to\repo `
  -TaskId feature-example `
  -TaskText "Implement the feature and prove all acceptance criteria." `
  -DeliveryMode deadline-aware

& "$skill\scripts\durable_loop.ps1" start -RepoRoot D:\path\to\repo -TaskId feature-example
& "$skill\scripts\durable_loop.ps1" status -RepoRoot D:\path\to\repo -TaskId feature-example
& "$skill\scripts\durable_loop.ps1" stop -RepoRoot D:\path\to\repo -TaskId feature-example

& "$skill\scripts\durable_loop.ps1" extend `
  -RepoRoot D:\path\to\repo `
  -TaskId feature-example `
  -AdditionalBudgetMinutes 720
```

If the supervisor exits during a Codex Desktop update, run the same `start` command. The durable state remains in the target repository and resumes at the last incomplete proof phase.

`start` resumes; it never resets the clock. To add time, stop the loop and use `extend`. In deadline-aware mode each fresh Worker receives the current budget pressure. More time permits justified in-scope quality work; less time prioritizes a coherent core, integration, critical tests, checkpoints, and an honest gap report. Required criteria remain required at every stage.

## State

Proof files:

```text
.agent/tasks/<TASK_ID>/
```

Supervisor state and logs:

```text
.agent/durable-loop/<TASK_ID>/
```

See [SKILL.md](SKILL.md) for the agent workflow and [references/DURABLE_RUNTIME.md](references/DURABLE_RUNTIME.md) for recovery semantics.

## Validate

```powershell
python .\scripts\verify_package.py
pwsh -NoProfile -File .\scripts\test_durable_loop.ps1
```

## License and attribution

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
