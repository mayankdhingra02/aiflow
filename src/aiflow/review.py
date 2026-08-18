from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from aiflow.codex_events import (
    write_codex_event_summary,
)
from aiflow.git import run_git
from aiflow.models import (
    ProjectRecord,
    TaskRecord,
)
from aiflow.prompts import (
    build_review_prompt,
)

MAX_DIFF_TOTAL = 100_000
MAX_DIFF_PER_FILE = 24_000
MAX_CONTEXT_FILE = 24_000

SENSITIVE_BASENAMES = {
    ".env",
    "auth.json",
    "credentials.json",
    "id_dsa",
    "id_ed25519",
    "id_rsa",
    "secrets.json",
}

SENSITIVE_SUFFIXES = {
    ".key",
    ".p12",
    ".pem",
    ".pfx",
}


@dataclass(frozen=True)
class GitReviewEvidence:
    status: str
    diff_stat: str
    changed_files: tuple[str, ...]
    untracked_files: tuple[str, ...]
    omitted_files: tuple[str, ...]
    diff_markdown: str


@dataclass(frozen=True)
class ReviewArtifacts:
    prompt_path: Path
    evidence_path: Path
    codex_summary_path: Path


def _looks_sensitive(
    path: str,
) -> bool:
    candidate = Path(path)

    basename = candidate.name.lower()

    if basename in SENSITIVE_BASENAMES:
        return True

    if basename.startswith(".env.") and basename not in {
        ".env.example",
        ".env.sample",
        ".env.template",
    }:
        return True

    if candidate.suffix.lower() in (SENSITIVE_SUFFIXES):
        return True

    lowered_parts = {part.lower() for part in candidate.parts}

    return bool(
        lowered_parts
        & {
            ".aws",
            ".ssh",
            "secrets",
        }
    )


def _read_limited_text(
    path: Path,
    *,
    limit: int,
) -> str:
    if not path.exists():
        return "[Aiflow: file is missing]"

    try:
        data = path.read_bytes()
    except OSError as exc:
        return f"[Aiflow: could not read file: {exc}]"

    if b"\x00" in data[:4096]:
        return "[Aiflow: binary file omitted]"

    truncated = len(data) > limit
    data = data[:limit]

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return "[Aiflow: non-UTF-8 file omitted]"

    if truncated:
        text += "\n… [truncated by Aiflow]"

    return text


def _safe_untracked_text(
    *,
    root: Path,
    relative_path: str,
) -> str | None:
    candidate = root / relative_path

    if candidate.is_symlink():
        return None

    try:
        resolved = candidate.resolve()
        resolved.relative_to(root.resolve())
    except (
        OSError,
        ValueError,
    ):
        return None

    if not resolved.is_file():
        return None

    return _read_limited_text(
        resolved,
        limit=MAX_DIFF_PER_FILE,
    )


def collect_git_review_evidence(
    root: Path,
) -> GitReviewEvidence:
    root = root.resolve()

    status = run_git(
        [
            "status",
            "--short",
        ],
        root,
        required=False,
    )

    diff_stat = run_git(
        [
            "diff",
            "--stat",
            "HEAD",
            "--",
        ],
        root,
        required=False,
    )

    tracked_output = run_git(
        [
            "diff",
            "--name-only",
            "HEAD",
            "--",
        ],
        root,
        required=False,
    )

    untracked_output = run_git(
        [
            "ls-files",
            "--others",
            "--exclude-standard",
        ],
        root,
        required=False,
    )

    changed_files = tuple(line.strip() for line in tracked_output.splitlines() if line.strip())

    untracked_files = tuple(line.strip() for line in untracked_output.splitlines() if line.strip())

    omitted_files: list[str] = []
    sections: list[str] = []
    current_size = 0

    for path in changed_files:
        if _looks_sensitive(path):
            omitted_files.append(path)
            sections.append(
                f"### {path}\n[Aiflow omitted this diff because the path may contain secrets.]"
            )
            continue

        diff = run_git(
            [
                "diff",
                "--no-ext-diff",
                "--no-color",
                "HEAD",
                "--",
                path,
            ],
            root,
            required=False,
        )

        if len(diff) > MAX_DIFF_PER_FILE:
            diff = diff[:MAX_DIFF_PER_FILE] + "\n… [file diff truncated by Aiflow]"

        section = f"### {path}\n<aiflow_diff>\n{diff}\n</aiflow_diff>"

        remaining = MAX_DIFF_TOTAL - current_size

        if remaining <= 0:
            break

        if len(section) > remaining:
            section = section[:remaining] + "\n… [total diff truncated by Aiflow]"

        sections.append(section)
        current_size += len(section)

    for path in untracked_files:
        if current_size >= MAX_DIFF_TOTAL:
            break

        if _looks_sensitive(path):
            omitted_files.append(path)
            sections.append(
                "### "
                f"{path} (untracked)\n"
                "[Aiflow omitted this file "
                "because the path may "
                "contain secrets.]"
            )
            continue

        text = _safe_untracked_text(
            root=root,
            relative_path=path,
        )

        if text is None:
            omitted_files.append(path)
            sections.append(
                f"### {path} (untracked)\n[Aiflow omitted this non-regular or unsafe file.]"
            )
            continue

        section = f"### {path} (untracked)\n<aiflow_new_file>\n{text}\n</aiflow_new_file>"

        remaining = MAX_DIFF_TOTAL - current_size

        if remaining <= 0:
            break

        if len(section) > remaining:
            section = section[:remaining] + "\n… [total diff truncated by Aiflow]"

        sections.append(section)
        current_size += len(section)

    diff_markdown = (
        "\n\n".join(sections) if sections else ("[Aiflow detected no local implementation diff.]")
    )

    return GitReviewEvidence(
        status=status,
        diff_stat=diff_stat,
        changed_files=changed_files,
        untracked_files=untracked_files,
        omitted_files=tuple(omitted_files),
        diff_markdown=diff_markdown,
    )


def _read_task_artifact(
    path: Path,
) -> str:
    return _read_limited_text(
        path,
        limit=MAX_CONTEXT_FILE,
    )


def prepare_review_artifacts(
    *,
    project: ProjectRecord,
    task: TaskRecord,
) -> ReviewArtifacts:
    task.task_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    events_path = task.task_dir / "codex-events.jsonl"

    codex_summary_path = task.task_dir / "codex-events-summary.json"

    write_codex_event_summary(
        events_path=events_path,
        summary_path=codex_summary_path,
    )

    evidence = collect_git_review_evidence(project.path)

    evidence_path = task.task_dir / "review-evidence.md"

    omitted = "\n".join(f"- {path}" for path in evidence.omitted_files) or "None"

    changed = "\n".join(f"- {path}" for path in evidence.changed_files) or "None"

    untracked = "\n".join(f"- {path}" for path in evidence.untracked_files) or "None"

    evidence_text = (
        "# Aiflow Review Evidence\n\n"
        "## Git status\n\n"
        "<aiflow_git_status>\n"
        f"{evidence.status or '(clean)'}\n"
        "</aiflow_git_status>\n\n"
        "## Diff stat\n\n"
        "<aiflow_diff_stat>\n"
        f"{evidence.diff_stat or '(none)'}\n"
        "</aiflow_diff_stat>\n\n"
        "## Tracked changed files\n\n"
        f"{changed}\n\n"
        "## Untracked files\n\n"
        f"{untracked}\n\n"
        "## Files omitted from content evidence\n\n"
        f"{omitted}\n\n"
        "## Implementation diff\n\n"
        f"{evidence.diff_markdown}\n"
    )

    evidence_path.write_text(
        evidence_text,
        encoding="utf-8",
    )

    plan_path = task.plan_path or task.task_dir / "plan.md"

    report_path = task.task_dir / "implementation-report.md"

    validation_path = task.task_dir / "validation-summary.json"

    prompt = build_review_prompt(
        project=project,
        task=task,
        plan_body=_read_task_artifact(plan_path),
        implementation_report=(_read_task_artifact(report_path)),
        validation_summary=(_read_task_artifact(validation_path)),
        codex_event_summary=(_read_task_artifact(codex_summary_path)),
        git_evidence=evidence_text,
    )

    prompt_path = task.task_dir / "review-prompt.md"

    prompt_path.write_text(
        prompt,
        encoding="utf-8",
    )

    return ReviewArtifacts(
        prompt_path=prompt_path,
        evidence_path=evidence_path,
        codex_summary_path=(codex_summary_path),
    )
