import json
import subprocess
from pathlib import Path

import pytest

from aiflow.constants import (
    PACKET_BODY_SEPARATOR,
    PACKET_END,
    PACKET_START,
)
from aiflow.db import Database
from aiflow.errors import PacketError
from aiflow.models import TaskStatus
from aiflow.packets import parse_packet
from aiflow.review import (
    compute_worktree_fingerprint,
)
from aiflow.review_loop import (
    ReviewVerdict,
    import_review_packet,
)


def _git(
    root: Path,
    *args: str,
) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )

    return result.stdout.strip()


def _setup(
    tmp_path: Path,
) -> tuple[
    Database,
    object,
    object,
    Path,
]:
    root = tmp_path / "repo"
    root.mkdir()

    _git(
        root,
        "init",
        "-b",
        "main",
    )

    _git(
        root,
        "config",
        "user.name",
        "Test User",
    )

    _git(
        root,
        "config",
        "user.email",
        "test@example.com",
    )

    (root / "app.py").write_text(
        "value = 1\n",
        encoding="utf-8",
    )

    _git(
        root,
        "add",
        "app.py",
    )

    _git(
        root,
        "commit",
        "-m",
        "initial",
    )

    base_sha = _git(
        root,
        "rev-parse",
        "HEAD",
    )

    db = Database(tmp_path / "aiflow.db")

    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=root,
        remote_url=None,
    )

    task_dir = tmp_path / "task"
    task_dir.mkdir()

    plan_path = task_dir / "plan.md"

    plan_path.write_text(
        ("# Implementation Plan\nUpdate app.py.\n"),
        encoding="utf-8",
    )

    task = db.create_task(
        task_id="demo-review-1234",
        project_id=project.id,
        title="Demo review",
        request="Update the value.",
        nonce="a" * 32,
        base_sha=base_sha,
        branch="main",
        task_dir=task_dir,
    )

    db.update_task_plan(
        task_id=task.id,
        plan_path=plan_path,
        recommended_model="terra",
        reasoning_effort="medium",
        risk_level="low",
        requires_human_approval=False,
    )

    db.update_task_status(
        task_id=task.id,
        status=(TaskStatus.WAITING_FOR_REVIEW),
    )

    task = db.get_task(task.id)

    assert task is not None

    return (
        db,
        project,
        task,
        root,
    )


def _packet(
    *,
    task: object,
    fingerprint: str,
    verdict: str,
    packet_id: str,
) -> str:
    payload = {
        "packet_version": 1,
        "packet_id": packet_id,
        "project_id": task.project_id,
        "task_id": task.id,
        "nonce": task.nonce,
        "stage": ("implementation_review"),
        "base_sha": task.base_sha,
        "review_fingerprint": (fingerprint),
        "execution": {
            "model_role": "luna",
            "reasoning_effort": "medium",
        },
        "risk": {
            "level": "medium",
            "touches_authentication": False,
            "touches_authorization": False,
            "touches_database": False,
            "destructive_change": False,
            "touches_secrets": False,
            ("touches_production_infrastructure"): False,
        },
        ("requires_human_approval_before_execution"): False,
    }

    return (
        f"{PACKET_START}\n"
        "```json\n"
        f"{json.dumps(payload)}\n"
        "```\n"
        f"{PACKET_BODY_SEPARATOR}\n"
        "# Implementation Review\n\n"
        "## Verdict\n"
        f"{verdict}\n\n"
        "## Findings\n"
        + ("None.\n" if verdict == "SHIP" else ("- P1: Fix retry behavior.\n"))
        + f"{PACKET_END}\n"
    )


def test_ship_review_completes_task(
    tmp_path: Path,
) -> None:
    (
        db,
        project,
        task,
        root,
    ) = _setup(tmp_path)

    fingerprint = compute_worktree_fingerprint(root)

    packet = parse_packet(
        _packet(
            task=task,
            fingerprint=fingerprint,
            verdict="SHIP",
            packet_id=("ship-review-12345678"),
        )
    )

    result = import_review_packet(
        db=db,
        project=project,
        task=task,
        packet=packet,
    )

    assert result.verdict == ReviewVerdict.SHIP

    updated = db.get_task(task.id)

    assert updated is not None

    assert updated.status == TaskStatus.COMPLETED


def test_changes_requested_creates_followup(
    tmp_path: Path,
) -> None:
    (
        db,
        project,
        task,
        root,
    ) = _setup(tmp_path)

    fingerprint = compute_worktree_fingerprint(root)

    packet = parse_packet(
        _packet(
            task=task,
            fingerprint=fingerprint,
            verdict=("CHANGES_REQUESTED"),
            packet_id=("changes-review-12345678"),
        )
    )

    result = import_review_packet(
        db=db,
        project=project,
        task=task,
        packet=packet,
    )

    assert result.verdict == ReviewVerdict.CHANGES_REQUESTED

    assert result.followup_prompt_path is not None

    assert result.followup_prompt_path.exists()

    updated = db.get_task(task.id)

    assert updated is not None

    assert updated.status == TaskStatus.REVIEW_IMPORTED

    assert updated.recommended_model == "luna"


def test_stale_review_is_rejected(
    tmp_path: Path,
) -> None:
    (
        db,
        project,
        task,
        root,
    ) = _setup(tmp_path)

    fingerprint = compute_worktree_fingerprint(root)

    (root / "app.py").write_text(
        "value = 999\n",
        encoding="utf-8",
    )

    packet = parse_packet(
        _packet(
            task=task,
            fingerprint=fingerprint,
            verdict="SHIP",
            packet_id=("stale-review-12345678"),
        )
    )

    with pytest.raises(
        PacketError,
        match="stale",
    ):
        import_review_packet(
            db=db,
            project=project,
            task=task,
            packet=packet,
        )
