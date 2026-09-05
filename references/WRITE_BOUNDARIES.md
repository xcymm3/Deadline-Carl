# Write boundaries

Read this reference when diagnosing an unexpected task-artifact write, integrating another Skill, or using `repair-boundary`.

## Three output classes

1. **Formal proof ledger** — `.agent/tasks/<TASK_ID>/`. It is phase-owned and accepts only the current allowlist.
2. **Transient auxiliary output** — `.agent/deadline-carl-scratch/<TASK_ID>/iteration-<NNN>-<PHASE>/`. Put temporary plans, audits, screenshots, traces, coverage, and auxiliary reports under `auxiliary/<skill>/`.
3. **Frozen product deliverables** — the normal project tree outside `.agent/tasks/`. Files such as `tokens.css`, application components, or `.hallmark/preflight.json` belong here only when the frozen task actually requires them.

An auxiliary Skill's instruction to state, preview, list, or report expected files does not authorize a new formal task file. Satisfy a communication-only requirement in the Worker response. During `build` or `fix`, durable implementation notes may use the relevant `progress.json` item's `note` or `proof` fields.

## Phase allowlists

`deadline-report.md` is allowed in every phase. The remaining paths are:

| Phase | Additional writable formal paths |
| --- | --- |
| `freeze` | `spec.md` |
| `build` | `progress.json` |
| `evidence` | `evidence.md`, `evidence.json`, `raw/**` |
| `verify` | `verdict.json`, `problems.md` |
| `fix` | `progress.json`, `evidence.md`, `evidence.json`, `raw/**` |

Every Worker prompt prints the expanded list. The process environment exposes:

```text
DEADLINE_CARL_FORMAL_TASK_DIR=<absolute task directory>
DEADLINE_CARL_SCRATCH_DIR=<absolute per-iteration scratch directory>
DEADLINE_CARL_ALLOWED_TASK_WRITES=["deadline-report.md",...]
DEADLINE_CARL_OUTPUT_DIR=<compatibility alias for scratch>
```

Repository guidance and other Skills cannot add paths to this list.

## Automatic created-file quarantine

After an iteration, the supervisor compares SHA-256 snapshots of formal task files. Automatic recovery is eligible only when every violation is `created:<safe-relative-path>` and each source is a normal file still inside the formal task directory. Reparse points, rooted paths, traversal segments, alternate data streams, missing files, or mixed violation types refuse recovery.

Eligible files move to a unique directory under that iteration's scratch path. `manifest.json` records the mode, task, phase, iteration, UTC timestamp, reason, original and destination paths, size, and SHA-256. The supervisor then recomputes the boundary against the pre-iteration snapshot.

A successful quarantine has these semantics:

- the Worker result is not accepted as phase completion;
- the remaining-work forecast from that iteration is not trusted;
- source-code changes outside the formal ledger remain untouched;
- the same phase is retried;
- `consecutiveFailures` increases, so repetition eventually blocks;
- status/history records `writeBoundaryStatus: quarantined` and the manifest.

Any failed recovery or remaining violation becomes a hard blocker.

## Repairing an older blocked loop

Use only while the supervisor and Worker are stopped:

```powershell
& scripts/durable_loop.ps1 repair-boundary `
  -RepoRoot D:\path\to\repo `
  -TaskId <TASK_ID>
```

The command requires a blocked state whose latest boundary record consists entirely of safe `created:` paths that still exist. It moves them under `.agent/deadline-carl-scratch/<TASK_ID>/repairs/`, writes the same manifest, changes `lastWriteBoundaryStatus` to `repaired`, records the prior failure count, and clears the blocker. It does not start the supervisor; resume with ordinary `start` after reviewing the manifest.

It refuses `modified:` and `deleted:` entries because moving those files could destroy or conceal authoritative proof state. It also refuses missing, unsafe, mixed, running, or non-blocked cases. Resolve those cases manually, then use `start -Force` only after the recorded cause is genuinely fixed.

## Hallmark example

Hallmark asks the agent to state exact expected file changes before editing. That requirement should be fulfilled in the Worker message. A temporary UI plan, if useful, goes to:

```text
<DEADLINE_CARL_SCRATCH_DIR>/auxiliary/hallmark/ui-build-plan.md
```

Hallmark's actual product files, such as `tokens.css` or `.hallmark/log.json`, remain in the project tree when they are part of the requested design work. They do not belong in `.agent/tasks/<TASK_ID>/`.
