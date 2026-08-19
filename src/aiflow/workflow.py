from __future__ import annotations

from pathlib import Path

from aiflow.db import Database
from aiflow.errors import (
    AiflowError,
    StateError,
)
from aiflow.models import (
    ProjectRecord,
    RunHistoryStatus,
    TaskStatus,
)
from aiflow.validation import (
    DEFAULT_TIMEOUT_SECONDS,
    ValidationSummary,
    run_project_validations,
)
from aiflow.validation_history import (
    allocate_validation_attempt,
)


def _validation_base(
    *,
    db: Database,
    task_id: str,
    artifact_dir: Path | None,
    run_history_id: int | None,
) -> tuple[
    Path,
    int | None,
]:
    task = db.get_task(task_id)

    if task is None:
        raise StateError(f"unknown task ID: {task_id}")

    if artifact_dir is not None or run_history_id is not None:
        if artifact_dir is None or run_history_id is None:
            raise StateError("artifact_dir and run_history_id must be provided together")

        return (
            artifact_dir,
            run_history_id,
        )

    latest_run = db.latest_run_history(task.id)

    if latest_run is not None:
        return (
            latest_run.artifact_dir,
            latest_run.id,
        )

    # Legacy tasks have no run_history row.
    # Their new validation attempts are still
    # immutable, but live below task_dir.
    return (
        task.task_dir,
        None,
    )


def _mark_validation_failed(
    *,
    db: Database,
    task_id: str,
    run_history_id: int | None,
) -> None:
    db.update_task_status(
        task_id=task_id,
        status=(TaskStatus.VALIDATION_FAILED),
    )

    if run_history_id is not None:
        db.update_run_history_status(
            history_id=run_history_id,
            status=(RunHistoryStatus.VALIDATION_FAILED),
        )


def validate_implemented_task(
    *,
    db: Database,
    project: ProjectRecord,
    task_id: str,
    timeout_seconds: int = (DEFAULT_TIMEOUT_SECONDS),
    artifact_dir: Path | None = None,
    run_history_id: int | None = None,
) -> ValidationSummary:
    task = db.get_task(task_id)

    if task is None:
        raise StateError(f"unknown task ID: {task_id}")

    if task.status not in {
        TaskStatus.IMPLEMENTED,
        TaskStatus.VALIDATION_FAILED,
        TaskStatus.REVIEW_READY,
        TaskStatus.WAITING_FOR_REVIEW,
        TaskStatus.FAILED,
    }:
        raise StateError(f"task cannot be validated from status {task.status.value}")

    (
        validation_base,
        associated_run_id,
    ) = _validation_base(
        db=db,
        task_id=task.id,
        artifact_dir=artifact_dir,
        run_history_id=run_history_id,
    )

    validation_attempt = allocate_validation_attempt(validation_base)

    db.update_task_status(
        task_id=task.id,
        status=TaskStatus.VALIDATING,
    )

    try:
        summary = run_project_validations(
            root=project.path,
            task_dir=(validation_attempt.artifact_dir),
            timeout_seconds=(timeout_seconds),
        )

    except KeyboardInterrupt:
        _mark_validation_failed(
            db=db,
            task_id=task.id,
            run_history_id=(associated_run_id),
        )

        raise

    except (
        AiflowError,
        OSError,
    ):
        _mark_validation_failed(
            db=db,
            task_id=task.id,
            run_history_id=(associated_run_id),
        )

        raise

    except Exception:
        _mark_validation_failed(
            db=db,
            task_id=task.id,
            run_history_id=(associated_run_id),
        )

        raise

    final_status = TaskStatus.REVIEW_READY if summary.passed else TaskStatus.VALIDATION_FAILED

    db.update_task_status(
        task_id=task.id,
        status=final_status,
    )

    if associated_run_id is not None:
        run_status = (
            RunHistoryStatus.REVIEW_READY
            if summary.passed
            else (RunHistoryStatus.VALIDATION_FAILED)
        )

        db.update_run_history_status(
            history_id=(associated_run_id),
            status=run_status,
        )

    return summary
