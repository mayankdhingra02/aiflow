from __future__ import annotations

from aiflow.db import Database
from aiflow.errors import AiflowError, StateError
from aiflow.models import ProjectRecord, TaskStatus
from aiflow.validation import (
    DEFAULT_TIMEOUT_SECONDS,
    ValidationSummary,
    run_project_validations,
)


def validate_implemented_task(
    *,
    db: Database,
    project: ProjectRecord,
    task_id: str,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
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

    db.update_task_status(
        task_id=task.id,
        status=TaskStatus.VALIDATING,
    )

    try:
        summary = run_project_validations(
            root=project.path,
            task_dir=task.task_dir,
            timeout_seconds=timeout_seconds,
        )
    except KeyboardInterrupt:
        db.update_task_status(
            task_id=task.id,
            status=(TaskStatus.VALIDATION_FAILED),
        )
        raise
    except (AiflowError, OSError):
        db.update_task_status(
            task_id=task.id,
            status=(TaskStatus.VALIDATION_FAILED),
        )
        raise
    except Exception:
        db.update_task_status(
            task_id=task.id,
            status=(TaskStatus.VALIDATION_FAILED),
        )
        raise

    final_status = TaskStatus.REVIEW_READY if summary.passed else TaskStatus.VALIDATION_FAILED

    db.update_task_status(
        task_id=task.id,
        status=final_status,
    )

    return summary
