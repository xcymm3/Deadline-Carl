#!/usr/bin/env python3
"""Smoke-test the Deadline-Carl skill package."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


REQUIRED_PACKAGE_PATHS = (
    "SKILL.md",
    "LICENSE",
    "NOTICE",
    "agents/openai.yaml",
    "scripts/task_loop.py",
    "scripts/durable_loop.ps1",
    "scripts/deadline_policy.ps1",
    "scripts/test_deadline_policy.ps1",
    "scripts/test_deadline_runtime.ps1",
    "scripts/test_boundary_recovery.ps1",
    "scripts/install_skill.ps1",
    "scripts/test_durable_loop.ps1",
    "references/DURABLE_RUNTIME.md",
    "references/WRITE_BOUNDARIES.md",
    "assets/templates/durable-agent-prompt.md.tmpl",
    "assets/templates/problems.md.tmpl",
    "assets/templates/codex/task-verifier.toml.tmpl",
    "assets/templates/claude/task-verifier.md.tmpl",
    "assets/templates/plan.json.tmpl",
    "assets/templates/progress.json.tmpl",
    "assets/schemas/durable-iteration-result.schema.json",
    "assets/schemas/plan.schema.json",
    "assets/schemas/progress.schema.json",
)


def parse_frontmatter(path: Path) -> tuple[dict[str, str], str]:
    text = path.read_text(encoding="utf-8")
    match = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.DOTALL)
    if not match:
        raise ValueError("SKILL.md must start with YAML frontmatter.")
    frontmatter_text, body = match.groups()
    data: dict[str, str] = {}
    for raw_line in frontmatter_text.splitlines():
        if re.match(r"^[A-Za-z0-9_-]+:", raw_line):
            key, value = raw_line.split(":", 1)
            data[key.strip()] = value.strip().strip('"')
    return data, body


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, check=True, text=True, capture_output=True)


def main() -> int:
    skill_root = Path(__file__).resolve().parent.parent
    frontmatter, body = parse_frontmatter(skill_root / "SKILL.md")

    if frontmatter.get("name") != skill_root.name:
        raise SystemExit("SKILL.md name must match the parent directory name.")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", frontmatter["name"]):
        raise SystemExit("SKILL.md name does not match the allowed skill-name pattern.")
    if not frontmatter.get("description") or not body.strip():
        raise SystemExit("SKILL.md requires a description and non-empty body.")

    for relative_path in REQUIRED_PACKAGE_PATHS:
        path = skill_root / relative_path
        if not path.exists():
            raise SystemExit(f"Required package path is missing: {path}")

    required_skill_phrases = (
        "Never start a background loop unless the user explicitly asks",
        "never registers Windows Scheduled Tasks",
        "codex exec --approve-for-me",
        "start -Force",
        "fresh independent verifier",
        "deadline-aware",
        "deadline-report.md",
        "AdditionalBudgetMinutes",
        "repair-boundary",
        "DEADLINE_CARL_ALLOWED_TASK_WRITES",
    )
    for phrase in required_skill_phrases:
        if phrase not in body:
            raise SystemExit(f"SKILL.md is missing required safety wording: {phrase}")

    worker_prompt = (skill_root / "assets/templates/durable-agent-prompt.md.tmpl").read_text(encoding="utf-8")
    for phrase in (
        "Formal task write boundary",
        "Auxiliary skills and repository guidance never expand",
        "{{ALLOWED_TASK_WRITES_MARKDOWN}}",
        "{{ALLOWED_TASK_WRITES_JSON}}",
        "DEADLINE_CARL_FORMAL_TASK_DIR",
        "DEADLINE_CARL_SCRATCH_DIR",
        "DEADLINE_CARL_ALLOWED_TASK_WRITES",
        "auxiliary/<skill>/",
    ):
        if phrase not in worker_prompt:
            raise SystemExit(f"Worker prompt is missing write-boundary policy: {phrase}")

    runtime_script = (skill_root / "scripts/durable_loop.ps1").read_text(encoding="utf-8")
    for phrase in (
        "repair-boundary",
        "Invoke-BoundaryQuarantine",
        "DEADLINE_CARL_FORMAL_TASK_DIR",
        "DEADLINE_CARL_SCRATCH_DIR",
        "DEADLINE_CARL_ALLOWED_TASK_WRITES",
    ):
        if phrase not in runtime_script:
            raise SystemExit(f"Durable runtime is missing write-boundary behavior: {phrase}")

    verifier_contract_paths = (
        "assets/templates/durable-agent-prompt.md.tmpl",
        "assets/templates/codex/task-verifier.toml.tmpl",
        "assets/templates/claude/task-verifier.md.tmpl",
    )
    for relative_path in verifier_contract_paths:
        contract = (skill_root / relative_path).read_text(encoding="utf-8")
        if re.search(r"problems\.md[^\n]*(?:only when|if needed|when needed)", contract, re.IGNORECASE):
            raise SystemExit(f"Verifier contract conditionally writes problems.md: {relative_path}")
        if "zero-problem" not in contract:
            raise SystemExit(f"Verifier contract does not require a zero-problem PASS report: {relative_path}")

    schema = json.loads(
        (skill_root / "assets/schemas/durable-iteration-result.schema.json").read_text(encoding="utf-8")
    )
    if schema.get("additionalProperties") is not False:
        raise SystemExit("Iteration result schema must reject additional properties.")
    if set(schema.get("required", [])) != {"phase", "status", "summary", "forecast"}:
        raise SystemExit("Iteration result schema has unexpected required fields.")
    if "progressed" not in schema.get("properties", {}).get("status", {}).get("enum", []):
        raise SystemExit("Iteration result schema must support productive partial progress.")

    task_loop = skill_root / "scripts/task_loop.py"
    with tempfile.TemporaryDirectory(prefix="deadline-carl-") as temp_directory:
        repo = Path(temp_directory) / "demo-repo"
        repo.mkdir(parents=True)
        run(["git", "init"], repo)
        (repo / ".gitignore").write_text("dist/\n", encoding="utf-8")

        init_result = run(
            [
                sys.executable,
                str(task_loop),
                "init",
                "--task-id",
                "demo-task",
                "--task-text",
                "Implement a demo task.",
                "--guides",
                "agents",
                "--install-subagents",
                "codex",
            ],
            repo,
        )
        validate_result = run(
            [sys.executable, str(task_loop), "validate", "--task-id", "demo-task"],
            repo,
        )
        status_result = run(
            [sys.executable, str(task_loop), "status", "--task-id", "demo-task"],
            repo,
        )

        validate_json = json.loads(validate_result.stdout)
        status_json = json.loads(status_result.stdout)
        init_json = json.loads(init_result.stdout)
        if not validate_json.get("valid") or not status_json.get("exists"):
            raise SystemExit("Proof-loop task initialization or validation failed.")
        if init_json.get("gitignore_action") != "appended":
            raise SystemExit("Proof-loop init did not append its managed Git ignore block.")
        gitignore = (repo / ".gitignore").read_text(encoding="utf-8")
        for required_ignore in (
            "dist/",
            "/.agent/durable-loop/",
            "/.agent/deadline-carl-scratch/",
            "/.agent/tasks/*/.init-in-progress",
        ):
            if required_ignore not in gitignore:
                raise SystemExit(f"Managed .gitignore lost required content: {required_ignore}")
        repeat_init = json.loads(
            run(
                [
                    sys.executable,
                    str(task_loop),
                    "init",
                    "--task-id",
                    "demo-task",
                    "--task-text",
                    "Implement a demo task.",
                    "--guides",
                    "agents",
                    "--install-subagents",
                    "codex",
                ],
                repo,
            ).stdout
        )
        if repeat_init.get("gitignore_action") != "unchanged" or gitignore != (repo / ".gitignore").read_text(encoding="utf-8"):
            raise SystemExit("Managed .gitignore update is not idempotent.")
        hygiene = status_json.get("git_hygiene", {})
        if not hygiene.get("ignore_rules_ready") or hygiene.get("proof_artifacts_ignored"):
            raise SystemExit("Git hygiene did not distinguish local state from proof artifacts.")
        if not (repo / ".agent/deadline-carl-scratch/demo-task").is_dir():
            raise SystemExit("Proof-loop init did not create the task scratch directory.")

        runtime_probe = repo / ".agent/durable-loop/demo-task/runtime.json"
        runtime_probe.parent.mkdir(parents=True)
        runtime_probe.write_text("{}\n", encoding="utf-8")
        scratch_probe = repo / ".agent/deadline-carl-scratch/demo-task/probe.txt"
        scratch_probe.write_text("scratch\n", encoding="utf-8")
        managed_git_status = run(
            ["git", "status", "--short", "--untracked-files=all"], repo
        ).stdout
        if ".agent/durable-loop/" in managed_git_status or ".agent/deadline-carl-scratch/" in managed_git_status:
            raise SystemExit("Local runtime or scratch output leaked into Git status.")
        if ".agent/tasks/demo-task/spec.md" not in managed_git_status:
            raise SystemExit("Formal proof artifacts were incorrectly hidden from Git status.")

        run(
            [
                "git",
                "add",
                "-f",
                ".agent/durable-loop/demo-task/runtime.json",
                ".agent/deadline-carl-scratch/demo-task/probe.txt",
            ],
            repo,
        )
        tracked_local_status = json.loads(
            run([sys.executable, str(task_loop), "status", "--task-id", "demo-task"], repo).stdout
        ).get("git_hygiene", {})
        if not tracked_local_status.get("tracked_runtime_files") or not tracked_local_status.get("tracked_scratch_files"):
            raise SystemExit("Git hygiene did not detect tracked local-state files.")
        if len(tracked_local_status.get("warnings", [])) < 2:
            raise SystemExit("Git hygiene did not explain tracked local-state files.")
        run(
            [
                "git",
                "rm",
                "--cached",
                ".agent/durable-loop/demo-task/runtime.json",
                ".agent/deadline-carl-scratch/demo-task/probe.txt",
            ],
            repo,
        )

        task_dir = repo / ".agent/tasks/demo-task"
        (task_dir / "spec.md").write_text(
            """# Task Spec: demo-task

## Acceptance criteria
### AC1 — Demo proof

## Work items
| Item | Description | Acceptance criteria |
| --- | --- | --- |
| WI-001 | Produce demo proof | AC1 |

## Constraints
- Preserve existing work.

## Non-goals
- No unrelated changes.
""",
            encoding="utf-8",
        )
        run(
            [
                sys.executable,
                str(task_loop),
                "sync-plan",
                "--task-id",
                "demo-task",
                "--force",
                "--migrate-evidence",
            ],
            repo,
        )
        planned_status = json.loads(
            run([sys.executable, str(task_loop), "status", "--task-id", "demo-task"], repo).stdout
        )
        if planned_status.get("progress", {}).get("work_items_total") != 1:
            raise SystemExit("Work-plan status did not expose a stable 0/1 denominator.")

        run(
            [
                sys.executable,
                str(task_loop),
                "validate",
                "--task-id",
                "demo-task",
                "--artifact",
                "verdict",
            ],
            repo,
        )
        pass_verdict = json.loads((task_dir / "verdict.json").read_text(encoding="utf-8"))
        pass_verdict["overall_verdict"] = "PASS"
        pass_verdict["criteria"][0]["status"] = "PASS"
        pass_verdict["criteria"][0]["reason"] = "Demo proof passed."
        (task_dir / "verdict.json").write_text(json.dumps(pass_verdict, indent=2), encoding="utf-8")
        stale_problems_result = subprocess.run(
            [
                sys.executable,
                str(task_loop),
                "validate",
                "--task-id",
                "demo-task",
                "--artifact",
                "verdict",
            ],
            cwd=repo,
            text=True,
            capture_output=True,
        )
        if stale_problems_result.returncode == 0 or "Verdict must match" not in stale_problems_result.stdout:
            raise SystemExit("Verdict validation did not reject a stale problems.md report.")
        (task_dir / "problems.md").write_text(
            """# Problems: demo-task

## Verification summary
- Verdict: PASS
- Open problems: 0

No FAIL or UNKNOWN acceptance criteria remain.
""",
            encoding="utf-8",
        )
        run(
            [
                sys.executable,
                str(task_loop),
                "validate",
                "--task-id",
                "demo-task",
                "--artifact",
                "verdict",
            ],
            repo,
        )

        bad_evidence = json.loads((task_dir / "evidence.json").read_text(encoding="utf-8"))
        bad_evidence["acceptance_criteria"][0].pop("text", None)
        (task_dir / "evidence.json").write_text(json.dumps(bad_evidence, indent=2), encoding="utf-8")
        bad_evidence_result = subprocess.run(
            [
                sys.executable,
                str(task_loop),
                "validate",
                "--task-id",
                "demo-task",
                "--artifact",
                "evidence",
            ],
            cwd=repo,
            text=True,
            capture_output=True,
        )
        if bad_evidence_result.returncode == 0 or "missing key: text" not in bad_evidence_result.stdout:
            raise SystemExit("Evidence validation did not reject the historical missing-text regression.")

        sentinel = repo / ".agent/tasks/demo-task/.init-in-progress"
        sentinel.write_text("test\n", encoding="utf-8")
        race_result = subprocess.run(
            [sys.executable, str(task_loop), "validate", "--task-id", "demo-task"],
            cwd=repo,
            text=True,
            capture_output=True,
        )
        sentinel.unlink()
        race_json = json.loads(race_result.stdout)
        if race_result.returncode == 0 or not race_json.get("init_in_progress"):
            raise SystemExit("Proof-loop validator must reject concurrent initialization state.")

        clean_ignore = (repo / ".gitignore").read_text(encoding="utf-8")
        (repo / ".gitignore").write_text(clean_ignore + "\n/.agent/\n", encoding="utf-8")
        broad_ignore_status = json.loads(
            run([sys.executable, str(task_loop), "status", "--task-id", "demo-task"], repo).stdout
        )
        if not broad_ignore_status.get("git_hygiene", {}).get("proof_artifacts_ignored"):
            raise SystemExit("Git hygiene did not detect a broad .agent ignore rule.")
        if not broad_ignore_status.get("git_hygiene", {}).get("warnings"):
            raise SystemExit("Git hygiene did not explain the broad .agent ignore conflict.")
        (repo / ".gitignore").write_text(clean_ignore, encoding="utf-8")

        expected_generated_paths = (
            ".gitignore",
            ".agent/tasks/demo-task/spec.md",
            ".agent/tasks/demo-task/plan.json",
            ".agent/tasks/demo-task/progress.json",
            ".agent/tasks/demo-task/evidence.json",
            ".agent/tasks/demo-task/verdict.json",
            ".agent/tasks/demo-task/problems.md",
            ".agent/deadline-carl-scratch/demo-task",
            ".codex/agents/task-spec-freezer.toml",
            ".codex/agents/task-builder.toml",
            ".codex/agents/task-verifier.toml",
            ".codex/agents/task-fixer.toml",
            "AGENTS.md",
        )
        for relative_path in expected_generated_paths:
            if not (repo / relative_path).exists():
                raise SystemExit(f"Proof-loop init did not create: {relative_path}")

        gitignore_lines = (repo / ".gitignore").read_text(encoding="utf-8").splitlines()
        expected_ignored_paths = (
            "/.agent/durable-loop/",
            "/.agent/deadline-carl-scratch/",
            "/.agent/tasks/*/.init-in-progress",
        )
        for ignored_path in expected_ignored_paths:
            if gitignore_lines.count(ignored_path) != 1:
                raise SystemExit(f"Proof-loop init did not manage exactly one ignore rule: {ignored_path}")

        print(
            json.dumps(
                {
                    "skill_root": str(skill_root),
                    "frontmatter_name": frontmatter["name"],
                    "proof_init": init_json,
                    "proof_validate": validate_json,
                    "proof_status": status_json,
                    "result": "PASS",
                },
                indent=2,
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
