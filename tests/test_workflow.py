from pathlib import Path

import pytest

from aiflow.db import Database
from aiflow.models import (
    ProjectRecord,
    TaskStatus,
)
from aiflow.validation import (
    ValidationCommand,
    ValidationResult,
    ValidationSummary,
)
from aiflow.workflow import (
    validate_implemented_task,
)


def _setup_task(
    tmp_path: Path,
) -> tuple[
    Database,
    ProjectRecord,
    str,
]:
    db = Database(tmp_path / "aiflow.db")

    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=tmp_path / "repo",
        remote_url=None,
    )

    task = db.create_task(
        task_id="demo-workflow-1234",
        project_id=project.id,
        title="Workflow test",
        request="Test workflow",
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=tmp_path / "task",
    )

    db.update_task_status(
        task_id=task.id,
        status=TaskStatus.IMPLEMENTED,
    )

    return db, project, task.id


def _successful_summary(
    tmp_path: Path,
) -> ValidationSummary:
    output_path = tmp_path / "validation.log"

    output_path.write_text(
        "passed\n",
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
                exit_code=0,
                duration_seconds=0.1,
                output_path=output_path,
            ),
        ),
        summary_path=(tmp_path / "summary.json"),
    )


def _failed_summary(
    tmp_path: Path,
) -> ValidationSummary:
    output_path = tmp_path / "validation.log"

    output_path.write_text(
        "failed\n",
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
                exit_code=1,
                duration_seconds=0.1,
                output_path=output_path,
            ),
        ),
        summary_path=(tmp_path / "summary.json"),
    )


def test_validation_success_marks_review_ready(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    summary = _successful_summary(tmp_path)

    monkeypatch.setattr(
        ("aiflow.workflow.run_project_validations"),
        lambda **_kwargs: summary,
    )

    result = validate_implemented_task(
        db=db,
        project=project,
        task_id=task_id,
    )

    assert result.passed is True

    task = db.get_task(task_id)

    assert task is not None
    assert task.status == TaskStatus.REVIEW_READY


def test_validation_failure_marks_validation_failed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    summary = _failed_summary(tmp_path)

    monkeypatch.setattr(
        ("aiflow.workflow.run_project_validations"),
        lambda **_kwargs: summary,
    )

    result = validate_implemented_task(
        db=db,
        project=project,
        task_id=task_id,
    )

    assert result.passed is False

    task = db.get_task(task_id)

    assert task is not None
    assert task.status == TaskStatus.VALIDATION_FAILED


def test_validation_exception_marks_validation_failed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    def fail_validation(
        **_kwargs: object,
    ) -> ValidationSummary:
        raise OSError("simulated validation failure")

    monkeypatch.setattr(
        ("aiflow.workflow.run_project_validations"),
        fail_validation,
    )

    with pytest.raises(
        OSError,
        match=("simulated validation failure"),
    ):
        validate_implemented_task(
            db=db,
            project=project,
            task_id=task_id,
        )

    task = db.get_task(task_id)

    assert task is not None
    assert task.status == TaskStatus.VALIDATION_FAILED


def test_validation_failed_task_can_be_revalidated(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    db.update_task_status(
        task_id=task_id,
        status=(TaskStatus.VALIDATION_FAILED),
    )

    summary = _successful_summary(tmp_path)

    monkeypatch.setattr(
        ("aiflow.workflow.run_project_validations"),
        lambda **_kwargs: summary,
    )

    result = validate_implemented_task(
        db=db,
        project=project,
        task_id=task_id,
    )

    assert result.passed is True

    task = db.get_task(task_id)

    assert task is not None
    assert task.status == TaskStatus.REVIEW_READY


def test_waiting_for_review_task_can_be_revalidated(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    db.update_task_status(
        task_id=task_id,
        status=(TaskStatus.WAITING_FOR_REVIEW),
    )

    summary = _successful_summary(tmp_path)

    monkeypatch.setattr(
        ("aiflow.workflow.run_project_validations"),
        lambda **_kwargs: summary,
    )

    result = validate_implemented_task(
        db=db,
        project=project,
        task_id=task_id,
    )

    assert result.passed is True

    task = db.get_task(task_id)

    assert task is not None
    assert task.status == TaskStatus.REVIEW_READY
