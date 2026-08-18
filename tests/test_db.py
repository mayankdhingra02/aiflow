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
