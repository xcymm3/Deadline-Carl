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
    "scripts/install_skill.ps1",
    "scripts/test_durable_loop.ps1",
    "references/DURABLE_RUNTIME.md",
    "assets/templates/durable-agent-prompt.md.tmpl",
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
    )
    for phrase in required_skill_phrases:
        if phrase not in body:
            raise SystemExit(f"SKILL.md is missing required safety wording: {phrase}")

    schema = json.loads(
        (skill_root / "assets/schemas/durable-iteration-result.schema.json").read_text(encoding="utf-8")
    )
    if schema.get("additionalProperties") is not False:
        raise SystemExit("Iteration result schema must reject additional properties.")
    if set(schema.get("required", [])) != {"phase", "status", "summary"}:
        raise SystemExit("Iteration result schema has unexpected required fields.")
    if "progressed" not in schema.get("properties", {}).get("status", {}).get("enum", []):
        raise SystemExit("Iteration result schema must support productive partial progress.")

    task_loop = skill_root / "scripts/task_loop.py"
    with tempfile.TemporaryDirectory(prefix="deadline-carl-") as temp_directory:
        repo = Path(temp_directory) / "demo-repo"
        repo.mkdir(parents=True)
        run(["git", "init"], repo)

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
        if not validate_json.get("valid") or not status_json.get("exists"):
            raise SystemExit("Proof-loop task initialization or validation failed.")

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

        expected_generated_paths = (
            ".agent/tasks/demo-task/spec.md",
            ".agent/tasks/demo-task/plan.json",
            ".agent/tasks/demo-task/progress.json",
            ".agent/tasks/demo-task/evidence.json",
            ".agent/tasks/demo-task/verdict.json",
            ".codex/agents/task-spec-freezer.toml",
            ".codex/agents/task-builder.toml",
            ".codex/agents/task-verifier.toml",
            ".codex/agents/task-fixer.toml",
            "AGENTS.md",
        )
        for relative_path in expected_generated_paths:
            if not (repo / relative_path).exists():
                raise SystemExit(f"Proof-loop init did not create: {relative_path}")

        print(
            json.dumps(
                {
                    "skill_root": str(skill_root),
                    "frontmatter_name": frontmatter["name"],
                    "proof_init": json.loads(init_result.stdout),
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
