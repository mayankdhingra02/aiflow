from pathlib import Path

from aiflow.db import Database
from aiflow.models import (
    RunKind,
)
from aiflow.run_history import (
    allocate_run,
    preview_next_run_artifacts,
)


def _setup(
    tmp_path: Path,
):
    db = Database(tmp_path / "aiflow.db")

    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=tmp_path / "repo",
        remote_url=None,
    )

    task = db.create_task(
        task_id="demo-run-history-1234",
        project_id=project.id,
        title="Run history",
        request="Test runs",
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=tmp_path / "task",
    )

    task.task_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    prompt = task.task_dir / "implementation-prompt.md"

    prompt.write_text(
        "first prompt\n",
        encoding="utf-8",
    )

    return (
        db,
        task,
        prompt,
    )


def test_preview_does_not_allocate_run(
    tmp_path: Path,
) -> None:
    db, task, _prompt = _setup(tmp_path)

    preview = preview_next_run_artifacts(
        db=db,
        task=task,
    )

    assert preview.artifact_dir == task.task_dir / "runs" / "001"

    assert preview.artifact_dir.exists() is False

    assert db.list_run_history(task.id) == []


def test_allocate_run_snapshots_prompt(
    tmp_path: Path,
) -> None:
    db, task, prompt = _setup(tmp_path)

    allocated = allocate_run(
        db=db,
        task=task,
        kind=RunKind.INITIAL,
        source_prompt_path=prompt,
        model_role="terra",
        reasoning_effort="medium",
    )

    assert allocated.record.sequence == 1

    assert allocated.artifacts.prompt_path.read_text(encoding="utf-8") == "first prompt\n"

    assert allocated.record.artifact_dir == task.task_dir / "runs" / "001"


def test_subsequent_run_does_not_modify_first(
    tmp_path: Path,
) -> None:
    db, task, prompt = _setup(tmp_path)

    first = allocate_run(
        db=db,
        task=task,
        kind=RunKind.INITIAL,
        source_prompt_path=prompt,
        model_role="terra",
        reasoning_effort="medium",
    )

    prompt.write_text(
        "second prompt\n",
        encoding="utf-8",
    )

    second = allocate_run(
        db=db,
        task=task,
        kind=RunKind.FOLLOWUP,
        source_prompt_path=prompt,
        model_role="luna",
        reasoning_effort="high",
    )

    assert first.record.sequence == 1

    assert second.record.sequence == 2

    assert first.artifacts.prompt_path.read_text(encoding="utf-8") == "first prompt\n"

    assert second.artifacts.prompt_path.read_text(encoding="utf-8") == "second prompt\n"
