from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from typer.testing import CliRunner

from aiflow.cli import app
from aiflow.constants import (
    PACKET_BODY_SEPARATOR,
    PACKET_END,
    PACKET_START,
)
from aiflow.db import Database
from aiflow.models import TaskStatus
from aiflow.review import (
    compute_worktree_fingerprint,
)

runner = CliRunner()


def _git(
    root: Path,
    *args: str,
) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )

    return result.stdout.strip()


def _setup_review_task(
    tmp_path: Path,
) -> tuple[
    Database,
    object,
    object,
    Path,
]:
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
        "user.name",
        "Test User",
    )

    _git(
        root,
        "config",
        "user.email",
        "test@example.com",
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

    base_sha = _git(
        root,
        "rev-parse",
        "HEAD",
    )

    (root / "app.py").write_text(
        "value = 2\n",
        encoding="utf-8",
    )

    db = Database(tmp_path / "aiflow.db")

    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=root,
        remote_url=None,
    )

    task_dir = tmp_path / "task"
    task_dir.mkdir()

    plan_path = task_dir / "plan.md"

    plan_path.write_text(
        ("# Implementation Plan\nUpdate app.py.\n"),
        encoding="utf-8",
    )

    task = db.create_task(
        task_id="demo-review-cli-1234",
        project_id=project.id,
        title="CLI review",
        request="Update the value.",
        nonce="a" * 32,
        base_sha=base_sha,
        branch="main",
        task_dir=task_dir,
    )

    db.update_task_plan(
        task_id=task.id,
        plan_path=plan_path,
        recommended_model="terra",
        reasoning_effort="medium",
        risk_level="low",
        requires_human_approval=False,
    )

    db.update_task_status(
        task_id=task.id,
        status=(TaskStatus.WAITING_FOR_REVIEW),
    )

    task = db.get_task(task.id)

    assert task is not None

    return (
        db,
        project,
        task,
        root,
    )


def _review_packet(
    *,
    task: object,
    fingerprint: str,
    verdict: str,
) -> str:
    payload = {
        "packet_version": 1,
        "packet_id": ("cli-review-packet-12345678"),
        "project_id": task.project_id,
        "task_id": task.id,
        "nonce": task.nonce,
        "stage": ("implementation_review"),
        "base_sha": task.base_sha,
        "review_fingerprint": (fingerprint),
        "execution": {
            "model_role": "luna",
            "reasoning_effort": "medium",
        },
        "risk": {
            "level": "medium",
            "touches_authentication": False,
            "touches_authorization": False,
            "touches_database": False,
            "destructive_change": False,
            "touches_secrets": False,
            ("touches_production_infrastructure"): False,
        },
        ("requires_human_approval_before_execution"): False,
    }

    findings = "None." if verdict == "SHIP" else "- P1: Fix retry behavior."

    return (
        f"{PACKET_START}\n"
        "```json\n"
        f"{json.dumps(payload)}\n"
        "```\n"
        f"{PACKET_BODY_SEPARATOR}\n"
        "# Implementation Review\n\n"
        "## Verdict\n"
        f"{verdict}\n\n"
        "## Findings\n"
        f"{findings}\n"
        f"{PACKET_END}\n"
    )


def _import_changes_review(
    *,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> tuple[
    Database,
    object,
    object,
    Path,
]:
    (
        db,
        project,
        task,
        root,
    ) = _setup_review_task(tmp_path)

    fingerprint = compute_worktree_fingerprint(root)

    packet_path = tmp_path / "review.txt"

    packet_path.write_text(
        _review_packet(
            task=task,
            fingerprint=fingerprint,
            verdict=("CHANGES_REQUESTED"),
        ),
        encoding="utf-8",
    )

    monkeypatch.setattr(
        "aiflow.cli._db",
        lambda: db,
    )

    imported = runner.invoke(
        app,
        [
            "import-review",
            "--file",
            str(packet_path),
        ],
    )

    assert imported.exit_code == 0

    return (
        db,
        project,
        task,
        root,
    )


def test_import_review_ship_completes_task(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    (
        db,
        _project,
        task,
        root,
    ) = _setup_review_task(tmp_path)

    fingerprint = compute_worktree_fingerprint(root)

    packet_path = tmp_path / "review.txt"

    packet_path.write_text(
        _review_packet(
            task=task,
            fingerprint=fingerprint,
            verdict="SHIP",
        ),
        encoding="utf-8",
    )

    monkeypatch.setattr(
        "aiflow.cli._db",
        lambda: db,
    )

    result = runner.invoke(
        app,
        [
            "import-review",
            "--file",
            str(packet_path),
        ],
    )

    assert result.exit_code == 0

    assert "SHIP" in result.stdout

    updated = db.get_task(task.id)

    assert updated is not None

    assert updated.status == TaskStatus.COMPLETED


def test_import_review_changes_requested_prepares_followup(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    (
        db,
        _project,
        task,
        _root,
    ) = _import_changes_review(
        monkeypatch=monkeypatch,
        tmp_path=tmp_path,
    )

    updated = db.get_task(task.id)

    assert updated is not None

    assert updated.status == TaskStatus.REVIEW_IMPORTED

    assert (task.task_dir / "followup-implementation-prompt.md").exists()


def test_followup_dry_run_accepts_reviewed_dirty_worktree(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    (
        db,
        project,
        task,
        root,
    ) = _import_changes_review(
        monkeypatch=monkeypatch,
        tmp_path=tmp_path,
    )

    captured_prompt: list[Path] = []

    def capture_command(
        spec: object,
    ) -> list[str]:
        captured_prompt.append(spec.prompt_path)

        return [
            "codex",
            "exec",
            "-",
        ]

    monkeypatch.setattr(
        "aiflow.cli.build_codex_command",
        capture_command,
    )

    result = runner.invoke(
        app,
        [
            "run",
            task.id,
            "--dry-run",
        ],
    )

    assert result.exit_code == 0

    assert "Follow-up implementation" in result.stdout

    assert "Dry run only" in result.stdout

    expected_prompt = task.task_dir / "runs" / "001" / "implementation-prompt.md"

    assert captured_prompt == [expected_prompt]

    assert expected_prompt.exists() is False

    assert db.list_run_history(task.id) == []

    assert project.path == root.resolve()


def test_followup_dry_run_rejects_changed_worktree(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    (
        _db_instance,
        _project,
        task,
        root,
    ) = _import_changes_review(
        monkeypatch=monkeypatch,
        tmp_path=tmp_path,
    )

    (root / "app.py").write_text(
        "value = 999\n",
        encoding="utf-8",
    )

    result = runner.invoke(
        app,
        [
            "run",
            task.id,
            "--dry-run",
        ],
    )

    assert result.exit_code == 1

    assert "working tree changed" in result.stdout


def test_failed_followup_points_to_validation_recovery(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    (
        db,
        _project,
        task,
        root,
    ) = _import_changes_review(
        monkeypatch=monkeypatch,
        tmp_path=tmp_path,
    )

    def fail_after_edit(
        _spec: object,
        *,
        events_path: Path | None = None,
    ) -> int:
        del events_path

        (root / "app.py").write_text(
            "value = 999\n",
            encoding="utf-8",
        )

        return 2

    monkeypatch.setattr(
        "aiflow.cli.execute_codex",
        fail_after_edit,
    )

    result = runner.invoke(
        app,
        [
            "run",
            task.id,
            "--execute",
            "--yes",
        ],
    )

    assert result.exit_code == 2

    assert "Codex pass failed" in result.stdout

    assert f"aiflow validate {task.id}" in result.stdout

    updated = db.get_task(task.id)

    assert updated is not None

    assert updated.status == TaskStatus.FAILED
