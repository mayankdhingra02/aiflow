from pathlib import Path

from aiflow.db import Database
from aiflow.models import TaskStatus


def test_followup_recommendation_is_persisted(
    tmp_path: Path,
) -> None:
    db = Database(tmp_path / "aiflow.db")

    db.upsert_project(
        project_id="demo",
        name="Demo",
        path=tmp_path / "repo",
        remote_url=None,
    )

    task = db.create_task(
        task_id="demo-followup-1234",
        project_id="demo",
        title="Follow-up",
        request="Fix review findings",
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=tmp_path / "task",
    )

    db.update_task_followup(
        task_id=task.id,
        recommended_model="luna",
        reasoning_effort="medium",
        risk_level="medium",
        requires_human_approval=False,
    )

    updated = db.get_task(task.id)

    assert updated is not None

    assert updated.status == TaskStatus.REVIEW_IMPORTED

    assert updated.recommended_model == "luna"

    assert updated.reasoning_effort == "medium"

    assert updated.risk_level == "medium"
