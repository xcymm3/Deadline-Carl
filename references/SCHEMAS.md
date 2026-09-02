# Artifact schemas

These are the required files for each task folder:

```text
.agent/tasks/TASK_ID/
  spec.md
  plan.json
  progress.json
  evidence.md
  evidence.json
  raw/
    build.txt
    test-unit.txt
    test-integration.txt
    lint.txt
    screenshot-1.png
  verdict.json
  problems.md
  deadline-report.md  # optional; written during deadline-aware last-call
```

## `plan.json` and `progress.json`

`plan.json` is frozen from the spec's `## Work items` table. Each mandatory item has a stable ID and one or more mapped acceptance criteria. Its spec hash prevents a Worker from shrinking the denominator after implementation begins.

`progress.json` contains exactly the same item IDs with one implementation state: `pending`, `in_progress`, `implemented`, or `blocked`. Builders and fixers may update implementation state, notes, and proof. Fresh verification progress is not self-reported: status derives it from the verifier verdict for each item's mapped criteria.

## `deadline-report.md`

This optional handoff is required when a Worker begins an iteration in the `last-call` deadline stage and the task is not already complete. It records:

- the usable end-to-end core currently delivered
- mandatory acceptance criteria still incomplete or unproven
- checks actually run and their outcomes
- a defensible estimate of the smallest additional active-time budget

It never replaces `evidence.json` or `verdict.json`, and it cannot turn a partial task into PASS.

## `evidence.json`

Required top-level keys:

- `task_id`
- `overall_status`
- `acceptance_criteria`
- `changed_files`
- `commands_for_fresh_verifier`
- `known_gaps`

Allowed status values:

- `PASS`
- `FAIL`
- `UNKNOWN`

Recommended shape:

```json
{
  "task_id": "my-task",
  "overall_status": "UNKNOWN",
  "acceptance_criteria": [
    {
      "id": "AC1",
      "text": "Describe the criterion",
      "status": "UNKNOWN",
      "proof": [
        {
          "type": "command",
          "path": ".agent/tasks/my-task/raw/test-unit.txt",
          "command": "npm test -- --runInBand",
          "exit_code": 0,
          "summary": "Targeted unit tests passed."
        }
      ],
      "gaps": []
    }
  ],
  "changed_files": [],
  "commands_for_fresh_verifier": [],
  "known_gaps": []
}
```

## `verdict.json`

Required top-level keys:

- `task_id`
- `overall_verdict`
- `criteria`
- `commands_run`
- `artifacts_used`

Allowed status values:

- `PASS`
- `FAIL`
- `UNKNOWN`

Recommended shape:

```json
{
  "task_id": "my-task",
  "overall_verdict": "UNKNOWN",
  "criteria": [
    {
      "id": "AC1",
      "status": "UNKNOWN",
      "reason": "Not yet verified."
    }
  ],
  "commands_run": [],
  "artifacts_used": []
}
```

## `problems.md`

The fresh verifier must replace this file on every verification pass. Start with a machine-checkable summary:

```text
# Problems: <TASK_ID>

## Verification summary
- Verdict: PASS, FAIL, or UNKNOWN
- Open problems: <number of FAIL or UNKNOWN criteria>
```

For `PASS`, write `Open problems: 0` and a short statement that no `FAIL` or `UNKNOWN` criteria remain. Do not preserve findings from an earlier verification pass.

For `FAIL` or `UNKNOWN`, add one section for every non-`PASS` criterion with:

- criterion id and text
- status
- why it is not proven
- minimal reproduction steps
- expected vs actual
- affected files
- smallest safe fix
- corrective hint in 1-3 sentences

## Validation script

Run:

```bash
scripts/task_loop.py validate --task-id <TASK_ID>
```

This checks:

- required file presence
- JSON parseability
- top-level key presence
- allowed status values
- task id consistency
- frozen plan/spec hashes and exact progress item coverage

Use `--artifact plan`, `progress`, `evidence`, or `verdict` for a phase gate. The supervisor calls this validator rather than duplicating evidence field checks in PowerShell.
