from __future__ import annotations

from pathlib import Path

from aiflow.db import Database
from aiflow.models import TaskStatus


def test_project_and_task_round_trip(tmp_path: Path) -> None:
    db = Database(tmp_path / "aiflow.db")
    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=tmp_path / "repo",
        remote_url="git@github.com:example/demo.git",
    )
    assert db.get_project("demo") == project

    task_dir = tmp_path / "task"
    task = db.create_task(
        task_id="demo-12345678",
        project_id="demo",
        title="Add page",
        request="Add a page",
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=task_dir,
    )
    assert task.status == TaskStatus.WAITING_FOR_PLAN

    db.update_task_plan(
        task_id=task.id,
        plan_path=task_dir / "plan.md",
        recommended_model="terra",
        reasoning_effort="medium",
        risk_level="medium",
        requires_human_approval=False,
    )
    updated = db.get_task(task.id)
    assert updated is not None
    assert updated.status == TaskStatus.READY_TO_RUN
    assert updated.recommended_model == "terra"
    assert updated.risk_level == "medium"
    assert updated.requires_human_approval is False


def test_upsert_project_updates_path_when_repository_moves(
    tmp_path: Path,
) -> None:
    db = Database(tmp_path / "aiflow.db")

    original_path = tmp_path / "old" / "repo"
    moved_path = tmp_path / "new" / "repo"

    db.upsert_project(
        project_id="demo",
        name="Demo",
        path=original_path,
        remote_url="git@github.com:example/demo.git",
    )

    updated = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=moved_path,
        remote_url="git@github.com:example/demo.git",
    )

    assert updated.path == moved_path.resolve()
    assert db.get_project_by_path(original_path) is None
    assert db.get_project_by_path(moved_path) is not None


def test_update_task_status(tmp_path: Path) -> None:
    db = Database(tmp_path / "aiflow.db")
    db.upsert_project(
        project_id="demo",
        name="Demo",
        path=tmp_path / "repo",
        remote_url=None,
    )

    task = db.create_task(
        task_id="demo-status-1234",
        project_id="demo",
        title="Status test",
        request="Test status updates",
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=tmp_path / "task",
    )

    db.update_task_status(
        task_id=task.id,
        status=TaskStatus.RUNNING,
    )

    updated = db.get_task(task.id)
    assert updated is not None
    assert updated.status == TaskStatus.RUNNING
