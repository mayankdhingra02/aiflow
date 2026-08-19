from pathlib import Path

from aiflow.db import Database
from aiflow.models import (
    ReviewHistoryStatus,
    TaskRecord,
)
from aiflow.review_history import (
    allocate_review_directory,
    get_review_by_sequence,
    latest_prepared_review,
    record_prepared_review,
)


def _setup(
    tmp_path: Path,
) -> tuple[
    Database,
    TaskRecord,
]:
    db = Database(tmp_path / "aiflow.db")

    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=tmp_path / "repo",
        remote_url=None,
    )

    task = db.create_task(
        task_id="demo-review-history-1234",
        project_id=project.id,
        title="Review history",
        request="Review it",
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=tmp_path / "task",
    )

    return db, task


def test_first_review_directory_is_001(
    tmp_path: Path,
) -> None:
    db, task = _setup(tmp_path)

    artifacts = allocate_review_directory(
        db=db,
        task=task,
    )

    assert artifacts.sequence == 1

    assert artifacts.artifact_dir == task.task_dir / "reviews" / "001"


def test_orphan_review_directory_is_not_reused(
    tmp_path: Path,
) -> None:
    db, task = _setup(tmp_path)

    first = allocate_review_directory(
        db=db,
        task=task,
    )

    assert first.sequence == 1

    second = allocate_review_directory(
        db=db,
        task=task,
    )

    assert second.sequence == 2

    assert first.artifact_dir != second.artifact_dir


def test_prepared_review_round_trip(
    tmp_path: Path,
) -> None:
    db, task = _setup(tmp_path)

    artifacts = allocate_review_directory(
        db=db,
        task=task,
    )

    prepared = record_prepared_review(
        db=db,
        task=task,
        artifacts=artifacts,
        run_id=None,
        fingerprint=("c" * 64),
    )

    assert prepared.record.status == ReviewHistoryStatus.PREPARED

    assert prepared.record.sequence == 1

    assert prepared.record.fingerprint == "c" * 64

    latest = latest_prepared_review(
        db=db,
        task=task,
    )

    assert latest is not None

    assert latest.record.id == prepared.record.id


def test_same_fingerprint_can_have_distinct_reviews(
    tmp_path: Path,
) -> None:
    db, task = _setup(tmp_path)

    fingerprint = "c" * 64

    first_paths = allocate_review_directory(
        db=db,
        task=task,
    )

    first = record_prepared_review(
        db=db,
        task=task,
        artifacts=first_paths,
        run_id=None,
        fingerprint=fingerprint,
    )

    second_paths = allocate_review_directory(
        db=db,
        task=task,
    )

    second = record_prepared_review(
        db=db,
        task=task,
        artifacts=second_paths,
        run_id=None,
        fingerprint=fingerprint,
    )

    assert first.record.fingerprint == second.record.fingerprint

    assert first.record.sequence == 1

    assert second.record.sequence == 2

    selected = get_review_by_sequence(
        db=db,
        task=task,
        sequence=2,
    )

    assert selected is not None

    assert selected.record.id == second.record.id
