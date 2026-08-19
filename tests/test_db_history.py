from pathlib import Path

from aiflow.db import Database
from aiflow.models import (
    ReviewHistoryStatus,
    RunHistoryStatus,
    RunKind,
)


def _database(
    tmp_path: Path,
) -> tuple[
    Database,
    str,
]:
    db = Database(tmp_path / "aiflow.db")

    db.upsert_project(
        project_id="demo",
        name="Demo",
        path=tmp_path / "repo",
        remote_url=None,
    )

    task = db.create_task(
        task_id="demo-history-1234",
        project_id="demo",
        title="History",
        request="Test history",
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=tmp_path / "task",
    )

    return db, task.id


def test_run_history_round_trip(
    tmp_path: Path,
) -> None:
    db, task_id = _database(tmp_path)

    assert db.next_run_sequence(task_id) == 1

    first = db.create_run_history(
        task_id=task_id,
        sequence=1,
        kind=RunKind.INITIAL,
        artifact_dir=(tmp_path / "task" / "runs" / "001"),
        model_role="terra",
        reasoning_effort="medium",
    )

    assert first.sequence == 1
    assert first.status == RunHistoryStatus.CREATED

    assert db.next_run_sequence(task_id) == 2

    db.update_run_history_status(
        history_id=first.id,
        status=(RunHistoryStatus.REVIEW_READY),
    )

    updated = db.get_run_history(first.id)

    assert updated is not None

    assert updated.status == RunHistoryStatus.REVIEW_READY

    assert db.latest_run_history(task_id) == updated


def test_review_history_round_trip(
    tmp_path: Path,
) -> None:
    db, task_id = _database(tmp_path)

    run = db.create_run_history(
        task_id=task_id,
        sequence=1,
        kind=RunKind.INITIAL,
        artifact_dir=(tmp_path / "task" / "runs" / "001"),
        model_role="luna",
        reasoning_effort="low",
    )

    review = db.create_review_history(
        task_id=task_id,
        sequence=1,
        artifact_dir=(tmp_path / "task" / "reviews" / "001"),
        run_id=run.id,
        fingerprint=("c" * 64),
    )

    assert review.status == ReviewHistoryStatus.PREPARED

    assert review.run_id == run.id

    db.mark_review_imported(
        history_id=review.id,
        verdict="SHIP",
        packet_id=("review-packet-1234"),
    )

    updated = db.get_review_history(review.id)

    assert updated is not None

    assert updated.status == ReviewHistoryStatus.IMPORTED

    assert updated.verdict == "SHIP"

    assert updated.packet_id == "review-packet-1234"


def test_history_is_task_scoped(
    tmp_path: Path,
) -> None:
    db, first_task = _database(tmp_path)

    second = db.create_task(
        task_id="demo-history-5678",
        project_id="demo",
        title="Second",
        request="Second task",
        nonce="d" * 32,
        base_sha="e" * 40,
        branch="main",
        task_dir=(tmp_path / "second-task"),
    )

    db.create_run_history(
        task_id=first_task,
        sequence=1,
        kind=RunKind.INITIAL,
        artifact_dir=(tmp_path / "task" / "runs" / "001"),
        model_role="terra",
        reasoning_effort="medium",
    )

    assert len(db.list_run_history(first_task)) == 1

    assert db.list_run_history(second.id) == []

    assert db.next_run_sequence(second.id) == 1
