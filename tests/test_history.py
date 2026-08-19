from pathlib import Path

import pytest

from aiflow.history import (
    ensure_review_directory,
    ensure_run_directory,
    history_sequence_name,
    legacy_review_artifacts,
    legacy_run_artifacts,
    review_directory,
    run_directory,
)
from aiflow.models import (
    TaskRecord,
    TaskStatus,
)


def _task(
    tmp_path: Path,
) -> TaskRecord:
    return TaskRecord(
        id="demo-history-1234",
        project_id="demo",
        title="History",
        request="Test history",
        status=TaskStatus.READY_TO_RUN,
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=tmp_path / "task",
        created_at=("2026-08-18T00:00:00+00:00"),
        updated_at=("2026-08-18T00:00:00+00:00"),
    )


def test_history_sequence_name() -> None:
    assert history_sequence_name(1) == "001"

    assert history_sequence_name(12) == "012"

    assert history_sequence_name(123) == "123"


def test_history_sequence_rejects_zero() -> None:
    with pytest.raises(
        ValueError,
        match="positive",
    ):
        history_sequence_name(0)


def test_run_and_review_directories_are_task_scoped(
    tmp_path: Path,
) -> None:
    task = _task(tmp_path)

    assert run_directory(
        task,
        1,
    ) == (task.task_dir / "runs" / "001")

    assert review_directory(
        task,
        2,
    ) == (task.task_dir / "reviews" / "002")


def test_history_directories_are_not_reused(
    tmp_path: Path,
) -> None:
    task = _task(tmp_path)

    first = ensure_run_directory(
        task,
        1,
    )

    assert first.exists()

    with pytest.raises(
        FileExistsError,
    ):
        ensure_run_directory(
            task,
            1,
        )

    review = ensure_review_directory(
        task,
        1,
    )

    assert review.exists()

    with pytest.raises(
        FileExistsError,
    ):
        ensure_review_directory(
            task,
            1,
        )


def test_legacy_artifact_detection(
    tmp_path: Path,
) -> None:
    task = _task(tmp_path)

    task.task_dir.mkdir(
        parents=True,
    )

    run_artifacts = legacy_run_artifacts(task)

    review_artifacts = legacy_review_artifacts(task)

    assert run_artifacts.present is False

    assert review_artifacts.present is False

    (task.task_dir / "implementation-report.md").write_text(
        "legacy run\n",
        encoding="utf-8",
    )

    (task.task_dir / "review.md").write_text(
        "legacy review\n",
        encoding="utf-8",
    )

    assert legacy_run_artifacts(task).present is True

    assert legacy_review_artifacts(task).present is True


def test_legacy_implementation_prompt_alone_is_not_a_run(
    tmp_path: Path,
) -> None:
    task = _task(tmp_path)

    task.task_dir.mkdir(
        parents=True,
    )

    (task.task_dir / "implementation-prompt.md").write_text(
        "ready for Codex\n",
        encoding="utf-8",
    )

    artifacts = legacy_run_artifacts(task)

    assert artifacts.implementation_prompt.exists()

    assert artifacts.present is False
