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
from aiflow.models import (
    ReviewHistoryStatus,
    TaskStatus,
)
from aiflow.packets import (
    parse_packet,
)
from aiflow.review import (
    compute_worktree_fingerprint,
)
from aiflow.review_history import (
    allocate_review_directory,
    record_prepared_review,
)
from aiflow.review_loop import (
    ReviewVerdict,
    followup_prompt_path,
    import_review_packet,
)


def _git(
    root: Path,
    *args: str,
) -> str:
    return subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _setup(
    tmp_path: Path,
):
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
        "user.email",
        "test@example.com",
    )

    _git(
        root,
        "config",
        "user.name",
        "Test User",
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

    db = Database(tmp_path / "aiflow.db")

    project = db.upsert_project(
        project_id="demo",
        name="Demo",
        path=root,
        remote_url=None,
    )

    task_dir = tmp_path / "task"

    task_dir.mkdir()

    task = db.create_task(
        task_id=("demo-review-import-1234"),
        project_id=project.id,
        title="Review import",
        request="Change app.py",
        nonce="a" * 32,
        base_sha=_git(
            root,
            "rev-parse",
            "HEAD",
        ),
        branch="main",
        task_dir=task_dir,
    )

    plan_path = task_dir / "plan.md"

    plan_path.write_text(
        "# Implementation Plan\nUpdate app.py.\n",
        encoding="utf-8",
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
        status=(TaskStatus.REVIEW_READY),
    )

    (root / "app.py").write_text(
        "value = 2\n",
        encoding="utf-8",
    )

    fingerprint = compute_worktree_fingerprint(root)

    paths = allocate_review_directory(
        db=db,
        task=task,
    )

    paths.fingerprint_path.write_text(
        fingerprint + "\n",
        encoding="utf-8",
    )

    prepared = record_prepared_review(
        db=db,
        task=task,
        artifacts=paths,
        run_id=None,
        fingerprint=fingerprint,
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
        prepared,
        fingerprint,
    )


def _review_packet(
    *,
    task,
    fingerprint: str,
    sequence: int | None,
    verdict: str,
    packet_id: str,
) -> str:
    payload = {
        "packet_version": 1,
        "packet_id": packet_id,
        "project_id": (task.project_id),
        "task_id": task.id,
        "nonce": task.nonce,
        "stage": ("implementation_review"),
        "base_sha": task.base_sha,
        "review_fingerprint": (fingerprint),
        "execution": {
            "model_role": "terra",
            "reasoning_effort": ("medium"),
        },
        "risk": {
            "level": "low",
            "touches_authentication": False,
            "touches_authorization": False,
            "touches_database": False,
            "destructive_change": False,
            "touches_secrets": False,
            ("touches_production_infrastructure"): False,
        },
        ("requires_human_approval_before_execution"): False,
    }

    if sequence is not None:
        payload["review_sequence"] = sequence

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
        "None.\n"
        f"{PACKET_END}\n"
    )


def test_history_review_imports_into_exact_review_directory(
    tmp_path: Path,
) -> None:
    (
        db,
        project,
        task,
        _root,
        prepared,
        fingerprint,
    ) = _setup(tmp_path)

    packet = parse_packet(
        _review_packet(
            task=task,
            fingerprint=fingerprint,
            sequence=1,
            verdict="SHIP",
            packet_id=("review-history-ship-1"),
        )
    )

    result = import_review_packet(
        db=db,
        project=project,
        task=task,
        packet=packet,
    )

    assert result.verdict == ReviewVerdict.SHIP

    assert result.review_path == prepared.artifacts.review_path

    assert result.raw_packet_path == prepared.artifacts.packet_path

    assert prepared.artifacts.review_path.exists()

    assert prepared.artifacts.packet_path.exists()

    assert not (task.task_dir / "review.md").exists()

    history = db.get_review_history(prepared.record.id)

    assert history is not None

    assert history.status == ReviewHistoryStatus.IMPORTED

    assert history.verdict == "SHIP"


def test_changes_requested_followup_lives_in_review_directory(
    tmp_path: Path,
) -> None:
    (
        db,
        project,
        task,
        _root,
        prepared,
        fingerprint,
    ) = _setup(tmp_path)

    packet = parse_packet(
        _review_packet(
            task=task,
            fingerprint=fingerprint,
            sequence=1,
            verdict=("CHANGES_REQUESTED"),
            packet_id=("review-history-change-1"),
        )
    )

    result = import_review_packet(
        db=db,
        project=project,
        task=task,
        packet=packet,
    )

    expected = prepared.artifacts.followup_prompt_path

    assert result.followup_prompt_path == expected

    assert expected.exists()

    assert followup_prompt_path(task) == expected


def test_history_task_rejects_review_without_sequence(
    tmp_path: Path,
) -> None:
    (
        db,
        project,
        task,
        _root,
        _prepared,
        fingerprint,
    ) = _setup(tmp_path)

    packet = parse_packet(
        _review_packet(
            task=task,
            fingerprint=fingerprint,
            sequence=None,
            verdict="SHIP",
            packet_id=("review-history-no-seq"),
        )
    )

    with pytest.raises(
        PacketError,
        match="review_sequence",
    ):
        import_review_packet(
            db=db,
            project=project,
            task=task,
            packet=packet,
        )


def test_wrong_review_sequence_is_rejected(
    tmp_path: Path,
) -> None:
    (
        db,
        project,
        task,
        _root,
        _prepared,
        fingerprint,
    ) = _setup(tmp_path)

    packet = parse_packet(
        _review_packet(
            task=task,
            fingerprint=fingerprint,
            sequence=2,
            verdict="SHIP",
            packet_id=("review-history-wrong-seq"),
        )
    )

    with pytest.raises(
        PacketError,
        match="review_sequence",
    ):
        import_review_packet(
            db=db,
            project=project,
            task=task,
            packet=packet,
        )
