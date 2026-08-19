from pathlib import Path

import pytest
from typer.testing import CliRunner

from aiflow.cli import app
from aiflow.db import Database
from aiflow.models import TaskStatus
from aiflow.review import ReviewArtifacts
from aiflow.validation import (
    ValidationCommand,
    ValidationResult,
    ValidationSummary,
)

runner = CliRunner()


def _setup_review_task(
    tmp_path: Path,
) -> tuple[
    Database,
    str,
]:
    db = Database(tmp_path / "aiflow.db")

    repo = tmp_path / "repo"

    repo.mkdir()

    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=repo,
        remote_url=None,
    )

    task_dir = tmp_path / "task"

    task_dir.mkdir()

    task = db.create_task(
        task_id="demo-review-1234",
        project_id=project.id,
        title="Review test",
        request=("Review current worktree"),
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=task_dir,
    )

    db.update_task_status(
        task_id=task.id,
        status=(TaskStatus.REVIEW_READY),
    )

    return db, task.id


def _summary(
    *,
    tmp_path: Path,
    passed: bool,
) -> ValidationSummary:
    output_path = tmp_path / "validation.log"

    output_path.write_text(
        ("passed\n" if passed else "failed\n"),
        encoding="utf-8",
    )

    return ValidationSummary(
        commands=(
            ValidationCommand(
                name="test",
                argv=("test-command",),
            ),
        ),
        results=(
            ValidationResult(
                name="test",
                argv=("test-command",),
                exit_code=(0 if passed else 1),
                duration_seconds=0.1,
                output_path=(output_path),
            ),
        ),
        summary_path=(tmp_path / "summary.json"),
    )


def test_prepare_review_revalidates_before_generating_artifacts(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, task_id = _setup_review_task(tmp_path)

    order: list[str] = []

    validation_summary = _summary(
        tmp_path=tmp_path,
        passed=True,
    )

    def fake_validate(
        **_kwargs: object,
    ) -> ValidationSummary:
        order.append("validate")

        return validation_summary

    prompt_path = tmp_path / "review-prompt.md"

    prompt_path.write_text(
        "review prompt",
        encoding="utf-8",
    )

    artifacts = ReviewArtifacts(
        prompt_path=(prompt_path),
        evidence_path=(tmp_path / "review-evidence.md"),
        codex_summary_path=(tmp_path / "codex-summary.json"),
        fingerprint_path=(tmp_path / "review-fingerprint.txt"),
        review_fingerprint=("c" * 64),
    )

    def fake_prepare(
        **_kwargs: object,
    ) -> ReviewArtifacts:
        order.append("prepare")

        return artifacts

    monkeypatch.setattr(
        "aiflow.cli._db",
        lambda: db,
    )

    monkeypatch.setattr(
        ("aiflow.cli.validate_repository_state"),
        lambda *_args, **_kwargs: None,
    )

    monkeypatch.setattr(
        ("aiflow.cli.validate_implemented_task"),
        fake_validate,
    )

    monkeypatch.setattr(
        ("aiflow.cli.prepare_review_artifacts"),
        fake_prepare,
    )

    result = runner.invoke(
        app,
        [
            "prepare-review",
            task_id,
            "--no-copy",
        ],
    )

    assert result.exit_code == 0

    assert order == [
        "validate",
        "prepare",
    ]

    task = db.get_task(task_id)

    assert task is not None

    review = db.latest_review_history(task_id)

    assert review is not None

    assert review.sequence == 1

    assert review.fingerprint == "c" * 64

    assert review.artifact_dir == task.task_dir / "reviews" / "001"


def test_prepare_review_stops_when_fresh_validation_fails(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, task_id = _setup_review_task(tmp_path)

    validation_summary = _summary(
        tmp_path=tmp_path,
        passed=False,
    )

    def fake_validate(
        **_kwargs: object,
    ) -> ValidationSummary:
        db.update_task_status(
            task_id=task_id,
            status=(TaskStatus.VALIDATION_FAILED),
        )

        return validation_summary

    def forbidden_prepare(
        **_kwargs: object,
    ) -> ReviewArtifacts:
        pytest.fail("review artifacts must not be generated after failed fresh validation")

    monkeypatch.setattr(
        "aiflow.cli._db",
        lambda: db,
    )

    monkeypatch.setattr(
        ("aiflow.cli.validate_repository_state"),
        lambda *_args, **_kwargs: None,
    )

    monkeypatch.setattr(
        ("aiflow.cli.validate_implemented_task"),
        fake_validate,
    )

    monkeypatch.setattr(
        ("aiflow.cli.prepare_review_artifacts"),
        forbidden_prepare,
    )

    result = runner.invoke(
        app,
        [
            "prepare-review",
            task_id,
            "--no-copy",
        ],
    )

    assert result.exit_code == 1

    task = db.get_task(task_id)

    assert task is not None

    assert task.status == TaskStatus.VALIDATION_FAILED

    assert db.list_review_history(task_id) == []

    reviews_dir = task.task_dir / "reviews"

    assert not reviews_dir.exists() or list(reviews_dir.iterdir()) == []
