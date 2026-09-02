#!/usr/bin/env python3
"""Initialize and validate repo-local task proof loop artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_ROOT = SCRIPT_DIR.parent
TEMPLATES_DIR = SKILL_ROOT / "assets" / "templates"

REQUIRED_TASK_FILES = [
    "spec.md",
    "plan.json",
    "progress.json",
    "evidence.md",
    "evidence.json",
    "verdict.json",
    "problems.md",
    "raw/build.txt",
    "raw/test-unit.txt",
    "raw/test-integration.txt",
    "raw/lint.txt",
    "raw/screenshot-1.png",
]

STATUS_VALUES = {"PASS", "FAIL", "UNKNOWN"}
PROGRESS_VALUES = {"pending", "in_progress", "implemented", "blocked"}
INIT_SENTINEL_FILE = ".init-in-progress"

PNG_PLACEHOLDER = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x04\x00\x00\x00\xb5\x1c\x0c\x02\x00\x00\x00\x0bIDATx\xdac\xfc"
    b"\xff\x1f\x00\x03\x03\x02\x00\xefe\xf6\xe4\x00\x00\x00\x00IEND\xaeB`\x82"
)

MANAGED_START = "<!-- repo-task-proof-loop:start -->"
MANAGED_END = "<!-- repo-task-proof-loop:end -->"
GITIGNORE_START = "# deadline-carl:local-state:start"
GITIGNORE_END = "# deadline-carl:local-state:end"
GITIGNORE_BLOCK = """# deadline-carl:local-state:start
/.agent/durable-loop/
/.agent/deadline-carl-scratch/
/.agent/tasks/*/.init-in-progress
# deadline-carl:local-state:end"""
CODEX_GUIDE_CANDIDATES = (
    Path("AGENTS.override.md"),
    Path("AGENTS.md"),
)
CLAUDE_GUIDE_CANDIDATES = (
    Path("CLAUDE.md"),
    Path(".claude") / "CLAUDE.md",
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def fail(message: str, exit_code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(exit_code)


def validate_task_id(task_id: str) -> str:
    if not task_id:
        fail("TASK_ID cannot be empty.")
    if "/" in task_id or "\\" in task_id or ".." in task_id:
        fail("TASK_ID must not contain path separators or '..'.")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", task_id):
        fail("TASK_ID may contain only letters, numbers, dot, underscore, and hyphen.")
    return task_id


def discover_repo_root(start: Path) -> Path:
    start = start.resolve()
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=start,
            check=True,
            capture_output=True,
            text=True,
        )
        git_root = result.stdout.strip()
        if git_root:
            return Path(git_root).resolve()
    except Exception:
        pass

    current = start
    while True:
        if (current / ".git").exists():
            return current
        if current.parent == current:
            return start
        current = current.parent


def relative_or_absolute(path: Path, base: Path) -> str:
    try:
        return str(path.resolve().relative_to(base.resolve()))
    except Exception:
        return str(path.resolve())


def path_chain(repo_root: Path, current: Path) -> list[Path]:
    repo_root = repo_root.resolve()
    current = current.resolve()
    chain = [repo_root]
    if repo_root == current:
        return chain
    try:
        rel = current.relative_to(repo_root)
    except ValueError:
        return chain
    cursor = repo_root
    for part in rel.parts:
        cursor = cursor / part
        chain.append(cursor)
    return chain


def guidance_candidates_for_directory(directory: Path) -> list[Path]:
    candidates: list[Path] = []
    for rel_path in (*CODEX_GUIDE_CANDIDATES, Path("CLAUDE.md"), Path(".claude") / "CLAUDE.md"):
        candidate = directory / rel_path
        if candidate.exists():
            candidates.append(candidate)

    rules_dir = directory / ".claude" / "rules"
    if rules_dir.is_dir():
        for candidate in sorted(path for path in rules_dir.rglob("*.md") if path.is_file()):
            if candidate.is_file():
                candidates.append(candidate)

    return candidates


def discover_guidance_files(repo_root: Path, current: Path) -> list[Path]:
    found: list[Path] = []
    seen: set[Path] = set()
    for directory in path_chain(repo_root, current):
        for candidate in guidance_candidates_for_directory(directory):
            if candidate.exists():
                resolved = candidate.resolve()
                if resolved not in seen:
                    found.append(candidate)
                    seen.add(resolved)
    return found


def load_text_template(name: str) -> str:
    path = TEMPLATES_DIR / name
    return path.read_text(encoding="utf-8")


def render_template(text: str, mapping: dict[str, str]) -> str:
    rendered = text
    for key, value in mapping.items():
        rendered = rendered.replace(f"{{{{{key}}}}}", value)
    return rendered


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def init_sentinel_path(task_dir: Path) -> Path:
    return task_dir / INIT_SENTINEL_FILE


def mark_init_in_progress(task_dir: Path) -> None:
    sentinel = init_sentinel_path(task_dir)
    sentinel.write_text(f"{utc_now_iso()}\n", encoding="utf-8")


def clear_init_in_progress(task_dir: Path) -> None:
    sentinel = init_sentinel_path(task_dir)
    try:
        sentinel.unlink()
    except FileNotFoundError:
        pass


def has_managed_block(path: Path) -> bool:
    if not path.exists():
        return False
    content = path.read_text(encoding="utf-8")
    return MANAGED_START in content and MANAGED_END in content


def write_text_file(path: Path, content: str, *, force: bool = False) -> bool:
    ensure_parent(path)
    if path.exists() and not force:
        return False
    path.write_text(content, encoding="utf-8")
    return True


def write_binary_file(path: Path, content: bytes, *, force: bool = False) -> bool:
    ensure_parent(path)
    if path.exists() and not force:
        return False
    path.write_bytes(content)
    return True


def upsert_managed_block(path: Path, block: str) -> str:
    ensure_parent(path)
    if path.exists():
        content = path.read_text(encoding="utf-8")
    else:
        content = ""

    if MANAGED_START in content and MANAGED_END in content:
        pattern = re.compile(
            re.escape(MANAGED_START) + r".*?" + re.escape(MANAGED_END),
            re.DOTALL,
        )
        new_content = pattern.sub(block.strip(), content).rstrip() + "\n"
        action = "updated"
    else:
        if content.strip():
            new_content = content.rstrip() + "\n\n" + block.strip() + "\n"
        else:
            new_content = block.strip() + "\n"
        action = "created" if not path.exists() else "appended"

    path.write_text(new_content, encoding="utf-8")
    return action


def upsert_gitignore(repo_root: Path) -> str:
    path = repo_root / ".gitignore"
    content = path.read_text(encoding="utf-8") if path.exists() else ""
    base_content = content
    if GITIGNORE_START in content and GITIGNORE_END in content:
        pattern = re.compile(
            re.escape(GITIGNORE_START) + r".*?" + re.escape(GITIGNORE_END),
            re.DOTALL,
        )
        base_content = pattern.sub("", content)

    managed_lines = set(GITIGNORE_BLOCK.splitlines()) | {"# Deadline-Carl local supervisor state"}
    base_lines = [line for line in base_content.splitlines() if line.strip() not in managed_lines]
    base_content = "\n".join(base_lines).rstrip()
    separator = "\n\n" if base_content else ""
    new_content = base_content + separator + GITIGNORE_BLOCK + "\n"
    if not path.exists():
        action = "created"
    elif new_content == content:
        action = "unchanged"
    elif GITIGNORE_START in content and GITIGNORE_END in content:
        action = "updated"
    else:
        action = "appended"

    if new_content != content:
        path.write_text(new_content, encoding="utf-8")
    return action


def git_output(repo_root: Path, arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=repo_root,
        text=True,
        capture_output=True,
    )


def git_path_is_ignored(repo_root: Path, relative_path: str) -> bool:
    result = git_output(repo_root, ["check-ignore", "-q", "--no-index", "--", relative_path])
    return result.returncode == 0


def git_tracked_files(repo_root: Path, relative_path: str) -> list[str]:
    result = git_output(repo_root, ["ls-files", "--", relative_path])
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line]


def git_status_entries(repo_root: Path, task_id: str) -> list[str]:
    result = git_output(
        repo_root,
        [
            "status",
            "--short",
            "--untracked-files=all",
            "--",
            ".gitignore",
            "AGENTS.md",
            "CLAUDE.md",
            ".codex/agents",
            ".claude/agents",
            f".agent/tasks/{task_id}",
            f".agent/durable-loop/{task_id}",
            f".agent/deadline-carl-scratch/{task_id}",
        ],
    )
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line]


def git_hygiene_status(repo_root: Path, task_id: str) -> dict[str, Any]:
    runtime_probe = f".agent/durable-loop/{task_id}/runtime.json"
    scratch_probe = f".agent/deadline-carl-scratch/{task_id}/probe.txt"
    sentinel_probe = f".agent/tasks/{task_id}/{INIT_SENTINEL_FILE}"
    proof_probe = f".agent/tasks/{task_id}/spec.md"
    tracked_runtime = git_tracked_files(repo_root, ".agent/durable-loop")
    tracked_scratch = git_tracked_files(repo_root, ".agent/deadline-carl-scratch")
    runtime_ignored = git_path_is_ignored(repo_root, runtime_probe)
    scratch_ignored = git_path_is_ignored(repo_root, scratch_probe)
    sentinel_ignored = git_path_is_ignored(repo_root, sentinel_probe)
    proof_ignored = git_path_is_ignored(repo_root, proof_probe)
    warnings: list[str] = []
    if proof_ignored:
        warnings.append("Proof artifacts under .agent/tasks are ignored by the repository's current rules.")
    if tracked_runtime:
        warnings.append("Runtime files are already tracked; ignore rules do not remove files from the Git index.")
    if tracked_scratch:
        warnings.append("Scratch files are already tracked; ignore rules do not remove files from the Git index.")
    if not runtime_ignored or not scratch_ignored or not sentinel_ignored:
        warnings.append("One or more Deadline-Carl local-state paths are not ignored.")
    return {
        "ignore_rules_ready": runtime_ignored and scratch_ignored and sentinel_ignored,
        "runtime_ignored": runtime_ignored,
        "scratch_ignored": scratch_ignored,
        "init_sentinel_ignored": sentinel_ignored,
        "proof_artifacts_ignored": proof_ignored,
        "tracked_runtime_files": tracked_runtime,
        "tracked_scratch_files": tracked_scratch,
        "managed_status_entries": git_status_entries(repo_root, task_id),
        "warnings": warnings,
    }


def placeholder_task_statement(task_file: str | None, task_text: str | None) -> str:
    if task_text:
        return task_text.strip()
    if task_file:
        try:
            return Path(task_file).read_text(encoding="utf-8").strip()
        except Exception as exc:
            return f"Unable to read task file `{task_file}` at init time: {exc}"
    return "TODO: paste or summarize the original user task here."


def guidance_bullets(repo_root: Path, current: Path) -> str:
    discovered = discover_guidance_files(repo_root, current)
    if not discovered:
        return "- None detected at init time."
    return "\n".join(f"- {relative_or_absolute(path, repo_root)}" for path in discovered)


def choose_claude_guide_path(repo_root: Path) -> Path:
    for rel_path in CLAUDE_GUIDE_CANDIDATES:
        candidate = repo_root / rel_path
        if has_managed_block(candidate):
            return candidate
    for rel_path in CLAUDE_GUIDE_CANDIDATES:
        candidate = repo_root / rel_path
        if candidate.exists():
            return candidate
    return repo_root / "CLAUDE.md"


def template_context(task_id: str, repo_root: Path, current: Path, task_file: str | None, task_text: str | None) -> dict[str, str]:
    return {
        "TASK_ID": task_id,
        "CREATED_AT": utc_now_iso(),
        "REPO_ROOT": str(repo_root.resolve()),
        "WORKING_DIR": str(current.resolve()),
        "GUIDANCE_SOURCES": guidance_bullets(repo_root, current),
        "TASK_STATEMENT": placeholder_task_statement(task_file, task_text),
    }


def install_task_files(task_dir: Path, context: dict[str, str], *, force: bool = False) -> list[str]:
    created: list[str] = []

    file_map = {
        task_dir / "spec.md": render_template(load_text_template("spec.md.tmpl"), context),
        task_dir / "plan.json": render_template(load_text_template("plan.json.tmpl"), context),
        task_dir / "progress.json": render_template(load_text_template("progress.json.tmpl"), context),
        task_dir / "evidence.md": render_template(load_text_template("evidence.md.tmpl"), context),
        task_dir / "evidence.json": render_template(load_text_template("evidence.json.tmpl"), context),
        task_dir / "verdict.json": render_template(load_text_template("verdict.json.tmpl"), context),
        task_dir / "problems.md": render_template(load_text_template("problems.md.tmpl"), context),
        task_dir / "raw" / "build.txt": load_text_template("raw.build.txt.tmpl"),
        task_dir / "raw" / "test-unit.txt": load_text_template("raw.test-unit.txt.tmpl"),
        task_dir / "raw" / "test-integration.txt": load_text_template("raw.test-integration.txt.tmpl"),
        task_dir / "raw" / "lint.txt": load_text_template("raw.lint.txt.tmpl"),
    }

    for path, content in file_map.items():
        if write_text_file(path, content, force=force):
            created.append(str(path))

    screenshot = task_dir / "raw" / "screenshot-1.png"
    if write_binary_file(screenshot, PNG_PLACEHOLDER, force=force):
        created.append(str(screenshot))

    return created


def install_codex_agents(repo_root: Path) -> list[str]:
    target_dir = repo_root / ".codex" / "agents"
    target_dir.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for template_name in (
        "task-spec-freezer.toml.tmpl",
        "task-builder.toml.tmpl",
        "task-verifier.toml.tmpl",
        "task-fixer.toml.tmpl",
    ):
        content = (TEMPLATES_DIR / "codex" / template_name).read_text(encoding="utf-8")
        target = target_dir / template_name.replace(".tmpl", "")
        target.write_text(content, encoding="utf-8")
        written.append(str(target))
    return written


def install_claude_agents(repo_root: Path) -> list[str]:
    target_dir = repo_root / ".claude" / "agents"
    target_dir.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for template_name in (
        "task-spec-freezer.md.tmpl",
        "task-builder.md.tmpl",
        "task-verifier.md.tmpl",
        "task-fixer.md.tmpl",
    ):
        content = (TEMPLATES_DIR / "claude" / template_name).read_text(encoding="utf-8")
        target = target_dir / template_name.replace(".tmpl", "")
        target.write_text(content, encoding="utf-8")
        written.append(str(target))
    return written


def update_guides(repo_root: Path, guides: str, install_subagents: str) -> dict[str, str]:
    actions: dict[str, str] = {}
    if guides == "none":
        return actions

    agents_guide = repo_root / "AGENTS.md"
    claude_guide = choose_claude_guide_path(repo_root)
    existing_claude_guides = [
        repo_root / rel_path
        for rel_path in CLAUDE_GUIDE_CANDIDATES
        if (repo_root / rel_path).exists()
    ]

    want_codex = install_subagents in {"both", "codex"}
    want_claude = install_subagents in {"both", "claude"}

    include_agents = guides in {"both", "agents"}
    include_claude = guides in {"both", "claude"}

    if guides == "auto":
        include_agents = agents_guide.exists()
        include_claude = bool(existing_claude_guides)

        if want_codex and not include_agents:
            include_agents = True
        if want_claude and not include_claude:
            include_claude = True

        if not include_agents and not include_claude:
            include_agents = True
            include_claude = True

    guide_targets: list[tuple[Path, str]] = []
    if include_agents:
        guide_targets.append((agents_guide, load_text_template("managed-block-agents.md.tmpl")))
    if include_claude:
        guide_targets.append((claude_guide, load_text_template("managed-block-claude.md.tmpl")))

    for path, template in guide_targets:
        action = upsert_managed_block(path, template)
        actions[str(path)] = action

    return actions


def json_load(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def acceptance_criteria_from_spec(content: str) -> dict[str, str]:
    criteria: dict[str, str] = {}
    heading_pattern = re.compile(
        r"(?m)^\s{0,3}#{2,6}\s+(AC\d+)\s*(?:[:—-]\s*)?([^\r\n]*)$"
    )
    list_pattern = re.compile(r"(?m)^\s*[-*+]\s+(AC\d+)\s*:\s*([^\r\n]+)$")
    for match in heading_pattern.finditer(content):
        criterion_id, text = match.groups()
        criteria[criterion_id] = text.strip() or criterion_id
    for match in list_pattern.finditer(content):
        criterion_id, text = match.groups()
        criteria[criterion_id] = text.strip()
    return criteria


def markdown_section(content: str, heading: str) -> str:
    match = re.search(
        rf"(?ms)^##\s+{re.escape(heading)}\s*$\n(.*?)(?=^##\s+|\Z)",
        content,
    )
    return match.group(1) if match else ""


def work_items_from_spec(content: str) -> list[dict[str, Any]]:
    criteria = acceptance_criteria_from_spec(content)
    sections = [
        markdown_section(content, "Work items"),
        markdown_section(content, "Backlog traceability"),
    ]
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    item_pattern = re.compile(r"\b(?:WI-\d+|[A-Z][A-Z0-9]*-[A-Z0-9][A-Z0-9-]*)\b")
    criterion_pattern = re.compile(r"\bAC\d+\b")

    for section in sections:
        if not section:
            continue
        for raw_line in section.splitlines():
            if not raw_line.lstrip().startswith("|"):
                continue
            cells = [cell.strip() for cell in raw_line.strip().strip("|").split("|")]
            if len(cells) < 2 or all(set(cell) <= {"-", ":", " "} for cell in cells):
                continue
            item_ids = item_pattern.findall(cells[0])
            ac_ids = criterion_pattern.findall(" ".join(cells[1:]))
            if not item_ids or not ac_ids:
                continue
            description = re.sub(r"`", "", cells[1]).strip()
            for item_id in item_ids:
                if item_id in seen or item_id.startswith("AC"):
                    continue
                items.append(
                    {
                        "id": item_id,
                        "title": description if description and not description.startswith("AC") else item_id,
                        "ac_ids": sorted(set(ac_ids), key=lambda value: int(value[2:])),
                        "mandatory": True,
                    }
                )
                seen.add(item_id)
        if items:
            break

    if not items:
        for criterion_id, text in sorted(criteria.items(), key=lambda pair: int(pair[0][2:])):
            items.append(
                {
                    "id": criterion_id,
                    "title": text,
                    "ac_ids": [criterion_id],
                    "mandatory": True,
                }
            )
    return items


def plan_digest(plan: dict[str, Any]) -> str:
    canonical = json.dumps(plan, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256_text(canonical)


def write_json(path: Path, data: Any) -> None:
    ensure_parent(path)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def migrate_evidence_text(task_dir: Path, criteria: dict[str, str]) -> bool:
    evidence_path = task_dir / "evidence.json"
    if not evidence_path.exists():
        return False
    evidence = json_load(evidence_path)
    changed = False
    if "changed_files" not in evidence:
        legacy_changed = evidence.get("production_files_changed_by_evidence_phase")
        evidence["changed_files"] = legacy_changed if isinstance(legacy_changed, list) else []
        changed = True
    for key in ("commands_for_fresh_verifier", "known_gaps"):
        if not isinstance(evidence.get(key), list):
            evidence[key] = []
            changed = True
    for item in evidence.get("acceptance_criteria", []):
        if not isinstance(item, dict):
            continue
        criterion_id = item.get("id")
        if criterion_id in criteria and (not item.get("text") or item.get("text") == "TODO"):
            item["text"] = criteria[criterion_id]
            changed = True
    if changed:
        write_json(evidence_path, evidence)
    return changed


def sync_work_plan(task_dir: Path, task_id: str, *, force: bool, migrate_evidence: bool) -> dict[str, Any]:
    spec_path = task_dir / "spec.md"
    if not spec_path.exists():
        fail(f"Cannot create work plan without spec.md: {spec_path}")
    spec_content = spec_path.read_text(encoding="utf-8")
    criteria = acceptance_criteria_from_spec(spec_content)
    items = work_items_from_spec(spec_content)
    if not criteria or not items:
        fail("Frozen spec must contain acceptance criteria and at least one work item.")
    spec_hash = sha256_text(spec_content)
    plan_path = task_dir / "plan.json"
    existing_plan = json_load(plan_path) if plan_path.exists() else None
    if (
        isinstance(existing_plan, dict)
        and existing_plan.get("items")
        and existing_plan.get("spec_sha256") != spec_hash
        and not force
    ):
        fail("spec.md changed after the work plan was frozen. Use sync-plan --force only with explicit contract authority.")

    plan = {
        "schema_version": 1,
        "task_id": task_id,
        "spec_sha256": spec_hash,
        "items": items,
    }
    write_json(plan_path, plan)

    progress_path = task_dir / "progress.json"
    existing_progress: dict[str, dict[str, Any]] = {}
    if progress_path.exists():
        loaded_progress = json_load(progress_path)
        for item in loaded_progress.get("items", []) if isinstance(loaded_progress, dict) else []:
            if isinstance(item, dict) and item.get("id"):
                existing_progress[str(item["id"])] = item

    evidence_status: dict[str, str] = {}
    evidence_path = task_dir / "evidence.json"
    if evidence_path.exists():
        evidence = json_load(evidence_path)
        for item in evidence.get("acceptance_criteria", []) if isinstance(evidence, dict) else []:
            if isinstance(item, dict) and item.get("id"):
                evidence_status[str(item["id"])] = str(item.get("status", "UNKNOWN"))

    progress_items: list[dict[str, Any]] = []
    for definition in items:
        existing = existing_progress.get(definition["id"], {})
        state = existing.get("state") if existing.get("state") in PROGRESS_VALUES else "pending"
        if state == "pending" and all(evidence_status.get(ac_id) == "PASS" for ac_id in definition["ac_ids"]):
            state = "implemented"
        progress_items.append(
            {
                "id": definition["id"],
                "state": state,
                "note": str(existing.get("note", "")),
                "proof": list(existing.get("proof", [])) if isinstance(existing.get("proof", []), list) else [],
            }
        )
    progress = {
        "schema_version": 1,
        "task_id": task_id,
        "plan_sha256": plan_digest(plan),
        "items": progress_items,
    }
    write_json(progress_path, progress)
    evidence_changed = migrate_evidence_text(task_dir, criteria) if migrate_evidence else False
    return {
        "plan": str(plan_path),
        "progress": str(progress_path),
        "work_items": len(items),
        "evidence_text_migrated": evidence_changed,
    }


def validate_evidence(data: Any, task_id: str) -> list[str]:
    errors: list[str] = []
    required_keys = {
        "task_id",
        "overall_status",
        "acceptance_criteria",
        "changed_files",
        "commands_for_fresh_verifier",
        "known_gaps",
    }
    if not isinstance(data, dict):
        return ["evidence.json must contain a JSON object."]
    missing = sorted(required_keys - set(data.keys()))
    if missing:
        errors.append(f"evidence.json missing keys: {', '.join(missing)}")
    if data.get("task_id") != task_id:
        errors.append("evidence.json task_id does not match the requested TASK_ID.")
    if data.get("overall_status") not in STATUS_VALUES:
        errors.append("evidence.json overall_status must be PASS, FAIL, or UNKNOWN.")
    criteria = data.get("acceptance_criteria")
    if not isinstance(criteria, list):
        errors.append("evidence.json acceptance_criteria must be a list.")
    else:
        for index, item in enumerate(criteria):
            if not isinstance(item, dict):
                errors.append(f"evidence.json acceptance_criteria[{index}] must be an object.")
                continue
            for key in ("id", "text", "status", "proof", "gaps"):
                if key not in item:
                    errors.append(f"evidence.json acceptance_criteria[{index}] missing key: {key}")
            if not isinstance(item.get("text"), str) or not item.get("text", "").strip() or item.get("text") == "TODO":
                errors.append(f"evidence.json acceptance_criteria[{index}].text must be a non-TODO string.")
            if item.get("status") not in STATUS_VALUES:
                errors.append(f"evidence.json acceptance_criteria[{index}].status must be PASS, FAIL, or UNKNOWN.")
            if not isinstance(item.get("proof"), list):
                errors.append(f"evidence.json acceptance_criteria[{index}].proof must be a list.")
            if not isinstance(item.get("gaps"), list):
                errors.append(f"evidence.json acceptance_criteria[{index}].gaps must be a list.")
            if item.get("status") == "PASS" and not item.get("proof"):
                errors.append(f"evidence.json acceptance_criteria[{index}] cannot PASS without proof.")
            if item.get("status") in {"FAIL", "UNKNOWN"} and not item.get("gaps"):
                errors.append(f"evidence.json acceptance_criteria[{index}] must explain non-PASS gaps.")
    return errors


def validate_plan(data: Any, task_id: str, spec_content: str | None = None) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["plan.json must contain a JSON object."]
    for key in ("schema_version", "task_id", "spec_sha256", "items"):
        if key not in data:
            errors.append(f"plan.json missing key: {key}")
    if data.get("task_id") != task_id:
        errors.append("plan.json task_id does not match the requested TASK_ID.")
    if data.get("schema_version") != 1:
        errors.append("plan.json schema_version must be 1.")
    scaffold = (
        spec_content is not None
        and bool(re.search(r"(?mi)^\s*(?:[-*+]\s+AC\d+\s*:|#{2,6}\s+AC\d+.*)\s*TODO\s*$", spec_content))
        and data.get("spec_sha256") == "TODO"
        and data.get("items") == []
    )
    if scaffold:
        return errors
    if spec_content is not None and data.get("spec_sha256") != sha256_text(spec_content):
        errors.append("plan.json does not match the frozen spec.md hash.")
    items = data.get("items")
    if not isinstance(items, list) or not items:
        errors.append("plan.json items must be a non-empty list.")
        return errors
    seen: set[str] = set()
    mapped_criteria: set[str] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            errors.append(f"plan.json items[{index}] must be an object.")
            continue
        for key in ("id", "title", "ac_ids", "mandatory"):
            if key not in item:
                errors.append(f"plan.json items[{index}] missing key: {key}")
        item_id = item.get("id")
        if not isinstance(item_id, str) or not item_id or item_id in seen:
            errors.append(f"plan.json items[{index}].id must be unique and non-empty.")
        else:
            seen.add(item_id)
        if not isinstance(item.get("ac_ids"), list) or not item.get("ac_ids"):
            errors.append(f"plan.json items[{index}].ac_ids must be a non-empty list.")
        else:
            mapped_criteria.update(str(value) for value in item.get("ac_ids", []))
    if spec_content is not None:
        defined_criteria = set(acceptance_criteria_from_spec(spec_content))
        unknown = sorted(mapped_criteria - defined_criteria)
        missing = sorted(defined_criteria - mapped_criteria)
        if unknown:
            errors.append(f"plan.json maps unknown acceptance criteria: {', '.join(unknown)}")
        if missing:
            errors.append(f"plan.json does not cover acceptance criteria: {', '.join(missing)}")
    return errors


def validate_progress(data: Any, task_id: str, plan: dict[str, Any] | None = None) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["progress.json must contain a JSON object."]
    for key in ("schema_version", "task_id", "plan_sha256", "items"):
        if key not in data:
            errors.append(f"progress.json missing key: {key}")
    if data.get("task_id") != task_id:
        errors.append("progress.json task_id does not match the requested TASK_ID.")
    if data.get("schema_version") != 1:
        errors.append("progress.json schema_version must be 1.")
    scaffold = (
        isinstance(plan, dict)
        and plan.get("spec_sha256") == "TODO"
        and plan.get("items") == []
        and data.get("plan_sha256") == "TODO"
        and data.get("items") == []
    )
    if scaffold:
        return errors
    if plan is not None and data.get("plan_sha256") != plan_digest(plan):
        errors.append("progress.json does not match plan.json.")
    items = data.get("items")
    if not isinstance(items, list):
        errors.append("progress.json items must be a list.")
        return errors
    seen: set[str] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            errors.append(f"progress.json items[{index}] must be an object.")
            continue
        for key in ("id", "state", "note", "proof"):
            if key not in item:
                errors.append(f"progress.json items[{index}] missing key: {key}")
        item_id = item.get("id")
        if not isinstance(item_id, str) or not item_id or item_id in seen:
            errors.append(f"progress.json items[{index}].id must be unique and non-empty.")
        else:
            seen.add(item_id)
        if item.get("state") not in PROGRESS_VALUES:
            errors.append(f"progress.json items[{index}].state must be one of {sorted(PROGRESS_VALUES)}.")
        if not isinstance(item.get("proof"), list):
            errors.append(f"progress.json items[{index}].proof must be a list.")
    if plan is not None:
        expected = {str(item.get("id")) for item in plan.get("items", []) if isinstance(item, dict)}
        if seen != expected:
            errors.append("progress.json item IDs must exactly match plan.json.")
    return errors


def validate_verdict(data: Any, task_id: str) -> list[str]:
    errors: list[str] = []
    required_keys = {"task_id", "overall_verdict", "criteria", "commands_run", "artifacts_used"}
    if not isinstance(data, dict):
        return ["verdict.json must contain a JSON object."]
    missing = sorted(required_keys - set(data.keys()))
    if missing:
        errors.append(f"verdict.json missing keys: {', '.join(missing)}")
    if data.get("task_id") != task_id:
        errors.append("verdict.json task_id does not match the requested TASK_ID.")
    if data.get("overall_verdict") not in STATUS_VALUES:
        errors.append("verdict.json overall_verdict must be PASS, FAIL, or UNKNOWN.")
    criteria = data.get("criteria")
    if not isinstance(criteria, list):
        errors.append("verdict.json criteria must be a list.")
    else:
        for index, item in enumerate(criteria):
            if not isinstance(item, dict):
                errors.append(f"verdict.json criteria[{index}] must be an object.")
                continue
            for key in ("id", "status", "reason"):
                if key not in item:
                    errors.append(f"verdict.json criteria[{index}] missing key: {key}")
            if item.get("status") not in STATUS_VALUES:
                errors.append(f"verdict.json criteria[{index}].status must be PASS, FAIL, or UNKNOWN.")
    return errors


def validate_problems(content: str, task_id: str, verdict: Any) -> list[str]:
    errors: list[str] = []
    header = re.search(r"\A# Problems:\s*(.+?)\s*$", content, re.MULTILINE)
    summary_verdict = re.search(r"(?m)^- Verdict:\s*(PASS|FAIL|UNKNOWN)\s*$", content)
    open_problems = re.search(r"(?m)^- Open problems:\s*(\d+)\s*$", content)

    if not header or header.group(1) != task_id:
        errors.append("problems.md must start with the requested TASK_ID.")
    if not summary_verdict:
        errors.append("problems.md must report Verdict as PASS, FAIL, or UNKNOWN.")
    if not open_problems:
        errors.append("problems.md must report a numeric Open problems count.")

    if not isinstance(verdict, dict):
        return errors

    expected_verdict = verdict.get("overall_verdict")
    non_pass_ids = [
        str(item.get("id"))
        for item in verdict.get("criteria", [])
        if isinstance(item, dict) and item.get("id") and item.get("status") in {"FAIL", "UNKNOWN"}
    ]
    if summary_verdict and summary_verdict.group(1) != expected_verdict:
        errors.append("problems.md Verdict must match verdict.json overall_verdict.")
    if open_problems and int(open_problems.group(1)) != len(non_pass_ids):
        errors.append("problems.md Open problems must match the FAIL and UNKNOWN criterion count.")

    if non_pass_ids:
        for criterion_id in non_pass_ids:
            pattern = rf"(?m)^###\s+{re.escape(criterion_id)}(?:\s*[:—-]|\s*$)"
            if not re.search(pattern, content):
                errors.append(f"problems.md is missing a section for {criterion_id}.")
    elif re.search(r"(?m)^###\s+", content):
        errors.append("problems.md PASS report must not preserve stale problem sections.")
    return errors


def cmd_init(args: argparse.Namespace) -> int:
    current = Path(args.repo_root).resolve() if args.repo_root else Path.cwd().resolve()
    repo_root = discover_repo_root(current)
    task_id = validate_task_id(args.task_id)
    task_dir = repo_root / ".agent" / "tasks" / task_id
    scratch_dir = repo_root / ".agent" / "deadline-carl-scratch" / task_id
    gitignore_action = upsert_gitignore(repo_root)
    task_dir.mkdir(parents=True, exist_ok=True)
    scratch_dir.mkdir(parents=True, exist_ok=True)
    mark_init_in_progress(task_dir)
    try:
        context = template_context(task_id, repo_root, current, args.task_file, args.task_text)
        created_files = install_task_files(task_dir, context, force=args.force)

        installed_agents: list[str] = []
        if args.install_subagents in {"both", "codex"}:
            installed_agents.extend(install_codex_agents(repo_root))
        if args.install_subagents in {"both", "claude"}:
            installed_agents.extend(install_claude_agents(repo_root))

        guide_actions = update_guides(repo_root, args.guides, args.install_subagents)

        result = {
            "repo_root": str(repo_root),
            "task_id": task_id,
            "task_dir": str(task_dir),
            "scratch_dir": str(scratch_dir),
            "gitignore_action": gitignore_action,
            "created_or_overwritten_task_files": created_files,
            "installed_or_refreshed_subagent_files": installed_agents,
            "guide_file_actions": guide_actions,
            "git_hygiene": git_hygiene_status(repo_root, task_id),
        }
        print(json.dumps(result, indent=2))
        return 0
    finally:
        clear_init_in_progress(task_dir)


def cmd_sync_plan(args: argparse.Namespace) -> int:
    current = Path(args.repo_root).resolve() if args.repo_root else Path.cwd().resolve()
    repo_root = discover_repo_root(current)
    task_id = validate_task_id(args.task_id)
    task_dir = repo_root / ".agent" / "tasks" / task_id
    if not task_dir.exists():
        fail(f"Task directory does not exist: {task_dir}")
    result = sync_work_plan(
        task_dir,
        task_id,
        force=bool(args.force),
        migrate_evidence=bool(args.migrate_evidence),
    )
    print(json.dumps(result, indent=2))
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    current = Path(args.repo_root).resolve() if args.repo_root else Path.cwd().resolve()
    repo_root = discover_repo_root(current)
    task_id = validate_task_id(args.task_id)
    task_dir = repo_root / ".agent" / "tasks" / task_id

    artifact = getattr(args, "artifact", "all")
    required_by_artifact = {
        "all": REQUIRED_TASK_FILES,
        "plan": ["spec.md", "plan.json", "progress.json"],
        "progress": ["plan.json", "progress.json"],
        "evidence": ["spec.md", "plan.json", "progress.json", "evidence.md", "evidence.json"],
        "verdict": ["spec.md", "plan.json", "progress.json", "evidence.json", "verdict.json", "problems.md"],
    }
    missing = [str(task_dir / rel) for rel in required_by_artifact[artifact] if not (task_dir / rel).exists()]
    errors: list[str] = []
    init_in_progress = init_sentinel_path(task_dir).exists()

    if not task_dir.exists():
        errors.append(f"Task directory does not exist: {task_dir}")
    elif init_in_progress:
        errors.append(
            f"Task initialization is still in progress: {init_sentinel_path(task_dir)}. "
            "Rerun validate after init completes."
        )

    evidence_path = task_dir / "evidence.json"
    verdict_path = task_dir / "verdict.json"
    problems_path = task_dir / "problems.md"
    spec_path = task_dir / "spec.md"
    plan_path = task_dir / "plan.json"
    progress_path = task_dir / "progress.json"
    plan: dict[str, Any] | None = None
    spec_content = spec_path.read_text(encoding="utf-8") if spec_path.exists() else None
    scaffold_spec = bool(
        spec_content
        and re.search(r"(?mi)^\s*(?:[-*+]\s+AC\d+\s*:|#{2,6}\s+AC\d+.*)\s*TODO\s*$", spec_content)
    )

    if artifact in {"all", "plan", "progress", "evidence", "verdict"} and plan_path.exists():
        try:
            plan = json_load(plan_path)
            errors.extend(validate_plan(plan, task_id, spec_content))
        except Exception as exc:
            errors.append(f"Failed to parse plan.json: {exc}")

    if artifact in {"all", "plan", "progress", "evidence", "verdict"} and progress_path.exists():
        try:
            progress = json_load(progress_path)
            errors.extend(validate_progress(progress, task_id, plan))
        except Exception as exc:
            errors.append(f"Failed to parse progress.json: {exc}")

    if artifact in {"all", "evidence", "verdict"} and evidence_path.exists() and not (artifact == "all" and scaffold_spec):
        try:
            evidence = json_load(evidence_path)
            errors.extend(validate_evidence(evidence, task_id))
        except Exception as exc:
            errors.append(f"Failed to parse evidence.json: {exc}")

    verdict: Any = None
    if artifact in {"all", "verdict"} and verdict_path.exists() and not (artifact == "all" and scaffold_spec):
        try:
            verdict = json_load(verdict_path)
            errors.extend(validate_verdict(verdict, task_id))
        except Exception as exc:
            errors.append(f"Failed to parse verdict.json: {exc}")

    if artifact in {"all", "verdict"} and problems_path.exists() and not (artifact == "all" and scaffold_spec):
        try:
            errors.extend(validate_problems(problems_path.read_text(encoding="utf-8"), task_id, verdict))
        except Exception as exc:
            errors.append(f"Failed to parse problems.md: {exc}")

    valid = not missing and not errors
    report = {
        "repo_root": str(repo_root),
        "task_id": task_id,
        "task_dir": str(task_dir),
        "init_in_progress": init_in_progress,
        "artifact": artifact,
        "valid": valid,
        "missing_files": missing,
        "errors": errors,
    }
    print(json.dumps(report, indent=2))
    return 0 if valid else 1


def cmd_status(args: argparse.Namespace) -> int:
    current = Path(args.repo_root).resolve() if args.repo_root else Path.cwd().resolve()
    repo_root = discover_repo_root(current)
    task_id = validate_task_id(args.task_id)
    task_dir = repo_root / ".agent" / "tasks" / task_id

    report: dict[str, Any] = {
        "repo_root": str(repo_root),
        "task_id": task_id,
        "task_dir": str(task_dir),
        "exists": task_dir.exists(),
        "init_in_progress": init_sentinel_path(task_dir).exists(),
        "scratch_dir": str(repo_root / ".agent" / "deadline-carl-scratch" / task_id),
        "git_hygiene": git_hygiene_status(repo_root, task_id),
        "required_files_present": {},
        "evidence_overall_status": None,
        "verdict_overall_status": None,
        "non_pass_criteria": [],
        "progress": {
            "work_items_total": 0,
            "implemented": 0,
            "in_progress": 0,
            "pending": 0,
            "blocked": 0,
            "verified": 0,
            "criteria_total": 0,
            "criteria_pass": 0,
            "criteria_fail": 0,
            "criteria_unknown": 0,
        },
    }

    for rel in REQUIRED_TASK_FILES:
        report["required_files_present"][rel] = (task_dir / rel).exists()

    evidence_path = task_dir / "evidence.json"
    evidence_criteria: dict[str, str] = {}
    if evidence_path.exists():
        try:
            evidence = json_load(evidence_path)
            report["evidence_overall_status"] = evidence.get("overall_status")
            for item in evidence.get("acceptance_criteria", []):
                if isinstance(item, dict) and item.get("id"):
                    evidence_criteria[str(item["id"])] = str(item.get("status", "UNKNOWN"))
            report["progress"]["criteria_total"] = len(evidence_criteria)
            report["progress"]["criteria_pass"] = sum(value == "PASS" for value in evidence_criteria.values())
            report["progress"]["criteria_fail"] = sum(value == "FAIL" for value in evidence_criteria.values())
            report["progress"]["criteria_unknown"] = sum(value == "UNKNOWN" for value in evidence_criteria.values())
        except Exception as exc:
            report["evidence_overall_status"] = f"PARSE_ERROR: {exc}"

    verdict_path = task_dir / "verdict.json"
    verdict_criteria: dict[str, str] = {}
    if verdict_path.exists():
        try:
            verdict = json_load(verdict_path)
            report["verdict_overall_status"] = verdict.get("overall_verdict")
            criteria = verdict.get("criteria", [])
            if isinstance(criteria, list):
                for item in criteria:
                    if isinstance(item, dict) and item.get("id"):
                        verdict_criteria[str(item["id"])] = str(item.get("status", "UNKNOWN"))
                    if isinstance(item, dict) and item.get("status") in {"FAIL", "UNKNOWN"}:
                        report["non_pass_criteria"].append(
                            {
                                "id": item.get("id"),
                                "status": item.get("status"),
                                "reason": item.get("reason"),
                            }
                        )
        except Exception as exc:
            report["verdict_overall_status"] = f"PARSE_ERROR: {exc}"

    plan_path = task_dir / "plan.json"
    progress_path = task_dir / "progress.json"
    if plan_path.exists() and progress_path.exists():
        try:
            plan = json_load(plan_path)
            progress = json_load(progress_path)
            definitions = {str(item["id"]): item for item in plan.get("items", []) if isinstance(item, dict) and item.get("id")}
            states = {str(item["id"]): str(item.get("state", "pending")) for item in progress.get("items", []) if isinstance(item, dict) and item.get("id")}
            report["progress"]["work_items_total"] = len(definitions)
            for state in PROGRESS_VALUES:
                report["progress"][state] = sum(value == state for value in states.values())
            report["progress"]["verified"] = sum(
                bool(definition.get("ac_ids"))
                and all(verdict_criteria.get(ac_id) == "PASS" for ac_id in definition.get("ac_ids", []))
                for definition in definitions.values()
            )
        except Exception as exc:
            report["progress_error"] = str(exc)

    def bar(done: int, total: int, width: int = 20) -> str:
        filled = 0 if total <= 0 else min(width, round(done * width / total))
        return "[" + "█" * filled + "░" * (width - filled) + f"] {done}/{total}"

    total = int(report["progress"]["work_items_total"])
    implemented = int(report["progress"]["implemented"])
    verified = int(report["progress"]["verified"])
    criteria_total = int(report["progress"]["criteria_total"])
    criteria_pass = int(report["progress"]["criteria_pass"])
    report["progress_display"] = {
        "implementation": bar(implemented, total),
        "verification": bar(verified, total),
        "acceptance": bar(criteria_pass, criteria_total),
    }

    print(json.dumps(report, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Repo task proof loop helper.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Initialize repo-local task artifacts and integration files.")
    init_parser.add_argument("--task-id", required=True, help="Task identifier, e.g. feature-auth-hardening")
    init_parser.add_argument("--task-file", help="Optional path to a task description file to seed spec.md")
    init_parser.add_argument("--task-text", help="Optional inline task text to seed spec.md")
    init_parser.add_argument("--repo-root", help="Optional working directory inside the repo. Defaults to the current directory.")
    init_parser.add_argument(
        "--guides",
        choices=["auto", "agents", "claude", "both", "none"],
        default="auto",
        help="Which guide files to create or update.",
    )
    init_parser.add_argument(
        "--install-subagents",
        choices=["both", "codex", "claude", "none"],
        default="both",
        help="Which project-scoped subagent sets to install or refresh.",
    )
    init_parser.add_argument("--force", action="store_true", help="Overwrite existing task artifact templates.")
    init_parser.set_defaults(func=cmd_init)

    sync_parser = subparsers.add_parser("sync-plan", help="Freeze or migrate the deterministic work-item plan.")
    sync_parser.add_argument("--task-id", required=True, help="Task identifier to plan.")
    sync_parser.add_argument("--repo-root", help="Optional working directory inside the repo. Defaults to the current directory.")
    sync_parser.add_argument("--force", action="store_true", help="Replace a plan after an explicitly authorized spec revision.")
    sync_parser.add_argument("--migrate-evidence", action="store_true", help="Backfill missing criterion text from spec.md.")
    sync_parser.set_defaults(func=cmd_sync_plan)

    validate_parser = subparsers.add_parser("validate", help="Validate required task files and JSON structures.")
    validate_parser.add_argument("--task-id", required=True, help="Task identifier to validate.")
    validate_parser.add_argument("--repo-root", help="Optional working directory inside the repo. Defaults to the current directory.")
    validate_parser.add_argument(
        "--artifact",
        choices=["all", "plan", "progress", "evidence", "verdict"],
        default="all",
        help="Validate the complete proof package or one phase gate.",
    )
    validate_parser.set_defaults(func=cmd_validate)

    status_parser = subparsers.add_parser("status", help="Summarize current task artifact status.")
    status_parser.add_argument("--task-id", required=True, help="Task identifier to summarize.")
    status_parser.add_argument("--repo-root", help="Optional working directory inside the repo. Defaults to the current directory.")
    status_parser.set_defaults(func=cmd_status)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
