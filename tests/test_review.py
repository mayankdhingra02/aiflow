from __future__ import annotations

import subprocess
from pathlib import Path

from aiflow.models import (
    ProjectRecord,
    TaskRecord,
    TaskStatus,
)
from aiflow.review import (
    collect_git_review_evidence,
    prepare_review_artifacts,
)


def _git(
    root: Path,
    *args: str,
) -> None:
    subprocess.run(
        [
            "git",
            *args,
        ],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )


def _setup_repository(
    tmp_path: Path,
) -> Path:
    root = tmp_path / "repo"

    root.mkdir()

    _git(
        root,
        "init",
        "-b",
        "main",
    )

    _git(
        root,
        "config",
        "user.email",
        "test@example.com",
    )

    _git(
        root,
        "config",
        "user.name",
        "Test User",
    )

    (root / "app.py").write_text(
        "value = 1\n",
        encoding="utf-8",
    )

    _git(
        root,
        "add",
        "app.py",
    )

    _git(
        root,
        "commit",
        "-m",
        "initial",
    )

    return root


def _base_sha(
    root: Path,
) -> str:
    return subprocess.run(
        [
            "git",
            "rev-parse",
            "HEAD",
        ],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _build_records(
    *,
    root: Path,
    task_dir: Path,
) -> tuple[
    ProjectRecord,
    TaskRecord,
]:
    project = ProjectRecord(
        id="demo",
        name="Demo",
        path=root,
        remote_url=None,
        created_at=("2026-01-01T00:00:00+00:00"),
        updated_at=("2026-01-01T00:00:00+00:00"),
    )

    task = TaskRecord(
        id="demo-task-1234",
        project_id=project.id,
        title="Demo task",
        request="Update the value.",
        status=TaskStatus.REVIEW_READY,
        nonce="a" * 32,
        base_sha=_base_sha(root),
        branch="main",
        task_dir=task_dir,
        plan_path=(task_dir / "plan.md"),
        recommended_model="terra",
        reasoning_effort="medium",
        risk_level="low",
        requires_human_approval=False,
        created_at=("2026-01-01T00:00:00+00:00"),
        updated_at=("2026-01-01T00:00:00+00:00"),
    )

    return project, task


def _write_review_artifacts(
    *,
    task_dir: Path,
    implementation_report: str,
) -> None:
    task_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    (task_dir / "plan.md").write_text(
        ("# Implementation Plan\nUpdate app.py.\n"),
        encoding="utf-8",
    )

    (task_dir / "implementation-report.md").write_text(
        implementation_report,
        encoding="utf-8",
    )

    (task_dir / "validation-summary.json").write_text(
        ('{"version":1,"passed":true}'),
        encoding="utf-8",
    )

    (task_dir / "codex-events.jsonl").write_text(
        ('{"type":"turn.completed","usage":{"input_tokens":10}}\n'),
        encoding="utf-8",
    )


def test_review_evidence_includes_changes_and_omits_sensitive_content(
    tmp_path: Path,
) -> None:
    root = _setup_repository(tmp_path)

    (root / "app.py").write_text(
        "value = 2\n",
        encoding="utf-8",
    )

    (root / "new_file.py").write_text(
        "created = True\n",
        encoding="utf-8",
    )

    (root / ".env").write_text(
        "SECRET=do-not-copy\n",
        encoding="utf-8",
    )

    evidence = collect_git_review_evidence(root)

    assert "app.py" in (evidence.changed_files)

    assert "new_file.py" in (evidence.untracked_files)

    assert ".env" in (evidence.untracked_files)

    assert ".env" in (evidence.omitted_files)

    assert "value = 2" in (evidence.diff_markdown)

    assert "created = True" in (evidence.diff_markdown)

    assert "do-not-copy" not in (evidence.diff_markdown)


def test_regular_source_file_with_credential_is_omitted(
    tmp_path: Path,
) -> None:
    root = _setup_repository(tmp_path)

    fake_secret = "sk-proj-" + ("A" * 40)

    (root / "app.py").write_text(
        (f'OPENAI_API_KEY = "{fake_secret}"\n'),
        encoding="utf-8",
    )

    evidence = collect_git_review_evidence(root)

    assert "app.py" in (evidence.omitted_files)

    assert fake_secret not in (evidence.diff_markdown)

    assert "credential-like material" in evidence.diff_markdown


def test_prepare_review_artifacts_writes_sanitized_sol_prompt(
    tmp_path: Path,
) -> None:
    root = _setup_repository(tmp_path)

    (root / "app.py").write_text(
        "value = 2\n",
        encoding="utf-8",
    )

    task_dir = tmp_path / "task"

    report = f"Updated app.py.\nRepository: {root}\nHome: {Path.home()}\n"

    _write_review_artifacts(
        task_dir=task_dir,
        implementation_report=report,
    )

    project, task = _build_records(
        root=root,
        task_dir=task_dir,
    )

    artifacts = prepare_review_artifacts(
        project=project,
        task=task,
    )

    assert artifacts.prompt_path.exists()

    assert artifacts.evidence_path.exists()

    assert artifacts.codex_summary_path.exists()

    prompt = artifacts.prompt_path.read_text(
        encoding="utf-8",
    )

    assert "AIFLOW_PACKET_V1" in prompt

    assert '"stage": "implementation_review"' in prompt

    assert '"review_fingerprint":' in prompt

    assert "value = 2" in prompt

    assert "Update the value." in prompt

    assert str(root) not in prompt

    assert str(Path.home()) not in prompt

    assert "<REPOSITORY_ROOT>" in prompt

    assert "<HOME>" in prompt

    fingerprint_path = task_dir / "review-fingerprint.txt"

    assert fingerprint_path.exists()

    fingerprint = fingerprint_path.read_text(encoding="utf-8").strip()

    assert len(fingerprint) == 64

    assert fingerprint in prompt


def test_codex_report_with_credential_is_omitted_from_review_prompt(
    tmp_path: Path,
) -> None:
    root = _setup_repository(tmp_path)

    (root / "app.py").write_text(
        "value = 2\n",
        encoding="utf-8",
    )

    task_dir = tmp_path / "task"

    fake_github_token = "ghp_" + ("A" * 36)

    _write_review_artifacts(
        task_dir=task_dir,
        implementation_report=(
            f"Implementation complete.\nAccidentally emitted token: {fake_github_token}\n"
        ),
    )

    project, task = _build_records(
        root=root,
        task_dir=task_dir,
    )

    artifacts = prepare_review_artifacts(
        project=project,
        task=task,
    )

    prompt = artifacts.prompt_path.read_text(
        encoding="utf-8",
    )

    assert fake_github_token not in prompt

    assert "Codex implementation report because credential-like material was detected" in prompt
