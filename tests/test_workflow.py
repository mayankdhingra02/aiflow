from pathlib import Path

import pytest

from aiflow.db import Database
from aiflow.models import (
    ProjectRecord,
    RunHistoryStatus,
    RunKind,
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


def test_failed_task_can_validate_to_review_ready(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    db.update_task_status(
        task_id=task_id,
        status=TaskStatus.FAILED,
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


def test_failed_task_can_validate_to_validation_failed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    db.update_task_status(
        task_id=task_id,
        status=TaskStatus.FAILED,
    )

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


def test_validation_uses_latest_run_directory(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    run_dir = tmp_path / "task" / "runs" / "001"

    run_dir.mkdir(
        parents=True,
    )

    run = db.create_run_history(
        task_id=task_id,
        sequence=1,
        kind=RunKind.INITIAL,
        artifact_dir=run_dir,
        model_role="terra",
        reasoning_effort="medium",
    )

    summary = _successful_summary(tmp_path)

    captured: dict[
        str,
        Path,
    ] = {}

    def fake_validation(
        *,
        root: Path,
        task_dir: Path,
        timeout_seconds: int,
    ) -> ValidationSummary:
        del root
        del timeout_seconds

        captured["task_dir"] = task_dir

        return summary

    monkeypatch.setattr(
        ("aiflow.workflow.run_project_validations"),
        fake_validation,
    )

    result = validate_implemented_task(
        db=db,
        project=project,
        task_id=task_id,
    )

    assert result.passed is True

    assert captured["task_dir"] == run_dir / "validations" / "001"

    updated_run = db.get_run_history(run.id)

    assert updated_run is not None

    assert updated_run.status == RunHistoryStatus.REVIEW_READY


def test_revalidation_creates_new_attempt_without_overwriting_first(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    db, project, task_id = _setup_task(tmp_path)

    run_dir = tmp_path / "task" / "runs" / "001"

    run_dir.mkdir(
        parents=True,
    )

    db.create_run_history(
        task_id=task_id,
        sequence=1,
        kind=RunKind.INITIAL,
        artifact_dir=run_dir,
        model_role="terra",
        reasoning_effort="medium",
    )

    called_dirs: list[Path] = []

    def fake_validation(
        *,
        root: Path,
        task_dir: Path,
        timeout_seconds: int,
    ) -> ValidationSummary:
        del root
        del timeout_seconds

        called_dirs.append(task_dir)

        output_path = task_dir / "validation.log"

        output_path.write_text(
            "passed\n",
            encoding="utf-8",
        )

        summary_path = task_dir / "validation-summary.json"

        summary_path.write_text(
            (f"attempt {len(called_dirs)}\n"),
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
                    output_path=(output_path),
                ),
            ),
            summary_path=(summary_path),
        )

    monkeypatch.setattr(
        ("aiflow.workflow.run_project_validations"),
        fake_validation,
    )

    first = validate_implemented_task(
        db=db,
        project=project,
        task_id=task_id,
    )

    first_text = first.summary_path.read_text(encoding="utf-8")

    second = validate_implemented_task(
        db=db,
        project=project,
        task_id=task_id,
    )

    assert called_dirs == [
        (run_dir / "validations" / "001"),
        (run_dir / "validations" / "002"),
    ]

    assert first.summary_path != second.summary_path

    assert first.summary_path.read_text(encoding="utf-8") == first_text

    assert second.summary_path.read_text(encoding="utf-8") == "attempt 2\n"
