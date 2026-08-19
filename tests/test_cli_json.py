import json
from pathlib import Path

import pytest
from typer.testing import CliRunner

from aiflow.cli import app
from aiflow.constants import MODEL_BY_ROLE
from aiflow.db import Database
from aiflow.models import (
    ModelRole,
    ReasoningEffort,
    TaskStatus,
)
from aiflow.review_history import (
    allocate_review_directory,
    record_prepared_review,
)

runner = CliRunner()


def _setup(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[
    Database,
    str,
    str,
]:
    db = Database(tmp_path / "aiflow.db")

    repo = tmp_path / "repo"

    repo.mkdir()

    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=repo,
        remote_url=None,
    )

    task_dir = tmp_path / "task"

    task_dir.mkdir()

    task = db.create_task(
        task_id="demo-json-1234",
        project_id=project.id,
        title="JSON output test",
        request="Verify JSON output",
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=task_dir,
    )

    monkeypatch.setattr(
        "aiflow.cli._db",
        lambda: db,
    )

    return db, project.id, task.id


def test_projects_json_outputs_decodable_array(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _db, project_id, _task_id = _setup(tmp_path, monkeypatch)

    result = runner.invoke(app, ["projects", "--json"])

    assert result.exit_code == 0

    payload = json.loads(result.stdout)

    assert isinstance(payload, list)

    assert payload[0]["id"] == project_id

    assert payload[0]["name"] == "Demo"


def test_tasks_json_outputs_decodable_array(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _db, _project_id, task_id = _setup(tmp_path, monkeypatch)

    result = runner.invoke(app, ["tasks", "--json"])

    assert result.exit_code == 0

    payload = json.loads(result.stdout)

    assert isinstance(payload, list)

    assert payload[0]["id"] == task_id

    assert payload[0]["status"] == "waiting_for_plan"


def test_show_json_includes_planner_prompt_path_when_present(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db, _project_id, task_id = _setup(tmp_path, monkeypatch)

    task = db.get_task(task_id)

    assert task is not None

    planner_prompt_path = task.task_dir / "planner-prompt.md"

    planner_prompt_path.write_text(
        "planning prompt\n",
        encoding="utf-8",
    )

    result = runner.invoke(app, ["show", task_id, "--json"])

    assert result.exit_code == 0

    payload = json.loads(result.stdout)

    assert payload["id"] == task_id

    assert payload["project_name"] == "Demo"

    assert payload["planner_prompt_path"] == str(planner_prompt_path)

    assert payload["review_prompt_path"] is None


def test_show_json_includes_review_prompt_path_from_latest_history(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db, _project_id, task_id = _setup(tmp_path, monkeypatch)

    task = db.get_task(task_id)

    assert task is not None

    db.update_task_status(
        task_id=task.id,
        status=TaskStatus.REVIEW_READY,
    )

    task = db.get_task(task_id)

    assert task is not None

    review_paths = allocate_review_directory(
        db=db,
        task=task,
    )

    review_prompt_path = review_paths.prompt_path

    review_prompt_path.write_text(
        "review prompt\n",
        encoding="utf-8",
    )

    record_prepared_review(
        db=db,
        task=task,
        artifacts=review_paths,
        run_id=None,
        fingerprint="c" * 64,
    )

    result = runner.invoke(app, ["show", task_id, "--json"])

    assert result.exit_code == 0

    payload = json.loads(result.stdout)

    assert payload["review_prompt_path"] == str(review_prompt_path)


def test_models_json_matches_backend_constants() -> None:
    result = runner.invoke(app, ["models", "--json"])

    assert result.exit_code == 0

    payload = json.loads(result.stdout)

    assert payload["models"] == [
        {"role": role.value, "model_id": MODEL_BY_ROLE[role.value]} for role in ModelRole
    ]

    assert payload["reasoning_efforts"] == [effort.value for effort in ReasoningEffort]

    assert payload["default_sandbox"] == "workspace-write"


def test_show_json_unknown_task_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _setup(tmp_path, monkeypatch)

    result = runner.invoke(app, ["show", "does-not-exist", "--json"])

    assert result.exit_code != 0
