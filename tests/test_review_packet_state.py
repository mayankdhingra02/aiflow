import json
from pathlib import Path

import pytest

from aiflow.constants import (
    PACKET_BODY_SEPARATOR,
    PACKET_END,
    PACKET_START,
)
from aiflow.errors import PacketError
from aiflow.models import (
    TaskRecord,
    TaskStatus,
)
from aiflow.packets import (
    parse_packet,
    validate_packet_for_task,
)


def _task(
    status: TaskStatus,
) -> TaskRecord:
    return TaskRecord(
        id="demo-review-1234",
        project_id="demo",
        title="Review",
        request="Review implementation",
        status=status,
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=Path("/tmp/task"),
        created_at=("2026-08-18T00:00:00+00:00"),
        updated_at=("2026-08-18T00:00:00+00:00"),
    )


def _packet(
    *,
    stage: str,
    task: TaskRecord,
    review_fingerprint: str | None = None,
    review_sequence: int | None = None,
) -> str:
    payload: dict[
        str,
        object,
    ] = {
        "packet_version": 1,
        "packet_id": ("review-packet-12345678"),
        "project_id": task.project_id,
        "task_id": task.id,
        "nonce": task.nonce,
        "stage": stage,
        "base_sha": task.base_sha,
        "execution": {
            "model_role": "terra",
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

    if review_sequence is not None:
        payload["review_sequence"] = review_sequence

    if review_fingerprint is not None:
        payload["review_fingerprint"] = review_fingerprint

    if stage == "implementation_review":
        body = (
            "# Implementation Review\n\n"
            "## Verdict\n"
            "CHANGES_REQUESTED\n\n"
            "## Findings\n"
            "- P1: Fix retry handling.\n"
        )
    else:
        body = "# Implementation Plan\n\nImplement the requested change.\n"

    return (
        f"{PACKET_START}\n"
        "```json\n"
        f"{json.dumps(payload)}\n"
        "```\n"
        f"{PACKET_BODY_SEPARATOR}\n"
        f"{body}"
        f"{PACKET_END}\n"
    )


@pytest.mark.parametrize(
    "status",
    [
        TaskStatus.REVIEW_READY,
        TaskStatus.WAITING_FOR_REVIEW,
    ],
)
def test_review_packet_accepts_review_states(
    status: TaskStatus,
) -> None:
    task = _task(status)

    packet = parse_packet(
        _packet(
            stage="implementation_review",
            task=task,
            review_fingerprint=("c" * 64),
            review_sequence=1,
        )
    )

    validate_packet_for_task(
        packet,
        task,
    )

    assert packet.envelope.review_sequence == 1

    assert packet.envelope.review_fingerprint == "c" * 64


def test_review_packet_rejects_non_review_state() -> None:
    task = _task(TaskStatus.READY_TO_RUN)

    packet = parse_packet(
        _packet(
            stage="implementation_review",
            task=task,
            review_fingerprint=("c" * 64),
            review_sequence=1,
        )
    )

    with pytest.raises(
        PacketError,
        match=("not waiting for an implementation review"),
    ):
        validate_packet_for_task(
            packet,
            task,
        )


def test_review_packet_requires_fingerprint() -> None:
    task = _task(TaskStatus.WAITING_FOR_REVIEW)

    packet = parse_packet(
        _packet(
            stage="implementation_review",
            task=task,
            review_sequence=1,
        )
    )

    with pytest.raises(
        PacketError,
        match=("implementation review must contain review_fingerprint"),
    ):
        validate_packet_for_task(
            packet,
            task,
        )


def test_legacy_review_packet_without_sequence_is_accepted() -> None:
    task = _task(TaskStatus.WAITING_FOR_REVIEW)

    packet = parse_packet(
        _packet(
            stage="implementation_review",
            task=task,
            review_fingerprint=("c" * 64),
            review_sequence=None,
        )
    )

    validate_packet_for_task(
        packet,
        task,
    )

    assert packet.envelope.review_sequence is None


def test_plan_rejects_review_sequence() -> None:
    task = _task(TaskStatus.WAITING_FOR_PLAN)

    packet = parse_packet(
        _packet(
            stage="implementation_plan",
            task=task,
            review_sequence=1,
        )
    )

    with pytest.raises(
        PacketError,
        match="review_sequence",
    ):
        validate_packet_for_task(
            packet,
            task,
        )


def test_plan_rejects_review_fingerprint() -> None:
    task = _task(TaskStatus.WAITING_FOR_PLAN)

    packet = parse_packet(
        _packet(
            stage="implementation_plan",
            task=task,
            review_fingerprint=("c" * 64),
        )
    )

    with pytest.raises(
        PacketError,
        match="review_fingerprint",
    ):
        validate_packet_for_task(
            packet,
            task,
        )
