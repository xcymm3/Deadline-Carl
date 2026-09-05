# Task Spec: write-boundary-recovery-v340

## Original task statement
Implement the four Deadline-Carl write-boundary fixes and update the locally installed Codex skill.

## Acceptance criteria

### AC1 — Worker receives an explicit phase write allowlist
Every generated Worker prompt prominently lists the exact formal task artifacts writable in the current phase. It states that auxiliary skills cannot expand this allowlist and that file-plan/reporting instructions should use the Worker response or an allowed `progress.json` field instead of creating an ad-hoc task Markdown file.

### AC2 — Worker receives a machine-readable path policy
Each iteration exports the formal task directory, scratch directory, and JSON-encoded allowed task writes through stable `DEADLINE_CARL_*` environment variables. The prompt distinguishes formal proof artifacts, transient auxiliary outputs, and in-scope project deliverables.

### AC3 — Created-only boundary violations are recoverable
When all boundary violations are newly created files under the formal task directory, the supervisor moves them into a unique per-iteration quarantine, records a manifest containing source, destination, hash, reason, and timestamp, confirms the formal boundary is restored, counts the iteration as a retry failure, preserves source-code changes, and blocks only after the configured consecutive-failure limit. Modified, deleted, unsafe, or mixed violations remain immediate hard blockers.

### AC4 — A restricted repair-boundary command repairs eligible blocked loops
`repair-boundary` works only on a stopped, blocked loop whose recorded violations are exclusively safe `created:` paths still present inside the formal task directory. It quarantines them with an audit manifest and clears the blocker without starting the loop. It refuses modified/deleted/missing/unsafe cases and records the repair in status/history fields.

### AC5 — Documentation, package validation, and regression tests cover the contract
Versioned Skill documentation explains the policy and recovery command. Automated tests cover prompt/environment injection, automatic quarantine and retry, hard blocking for protected-file changes, successful manual repair, and refusal cases. Package validation and the Skill Creator validator pass.

### AC6 — Source, remote, and installed Skill are synchronized
The implementation is committed with a Conventional Commit message, pushed to the configured remote branch, installed into the active Codex Skill directory with a recoverable backup, and verified file-for-file against the source package.

## Work items

| Item | Description | Acceptance criteria |
| --- | --- | --- |
| WI-001 | Add phase policy generation and Worker prompt/environment injection | AC1, AC2 |
| WI-002 | Implement safe automatic quarantine and retry accounting | AC3 |
| WI-003 | Implement restricted `repair-boundary` recovery | AC4 |
| WI-004 | Add regression tests and package checks | AC3, AC4, AC5 |
| WI-005 | Update Skill instructions, reference docs, README, and version | AC1, AC2, AC4, AC5 |
| WI-006 | Verify, commit, push, install, and compare the package | AC6 |

## Constraints

- Preserve the strict phase allowlist; do not add wildcard Markdown permissions.
- Never auto-quarantine modifications or deletions of existing formal proof artifacts.
- Quarantine must be recoverable, collision-safe, auditable, and confined to Deadline-Carl scratch state.
- A recovered automatic violation must not be treated as a successful phase completion.
- `repair-boundary` must not start the supervisor or silently accept unresolved violations.
- Preserve unrelated user changes and existing Git history.

## Non-goals

- Do not change Hallmark itself.
- Do not relax final proof validation.
- Do not stop or restart unrelated running Deadline-Carl loops.
- Do not migrate the active local Skill directory to a different discovery root.

## Quality opportunities

- Q1: Keep detailed write-boundary rules in one focused reference while leaving `SKILL.md` concise.

## Verification plan

- Run the dedicated boundary-recovery regression test.
- Run the durable-loop end-to-end test, including the existing protected-file hard-block case.
- Run deadline policy/runtime tests and `scripts/verify_package.py`.
- Run the Skill Creator `quick_validate.py` validator.
- Compare source and installed package file hashes after installation.
- Confirm local `main`, `origin/main`, and the implementation commit agree.
