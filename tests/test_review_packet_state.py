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


def _review_packet() -> str:
    payload = {
        "packet_version": 1,
        "packet_id": ("review-packet-12345678"),
        "project_id": "demo",
        "task_id": ("demo-review-1234"),
        "nonce": "a" * 32,
        "stage": ("implementation_review"),
        "base_sha": "b" * 40,
        "review_fingerprint": ("c" * 64),
        "execution": {
            "model_role": "terra",
            "reasoning_effort": "medium",
        },
        "risk": {
            "level": "medium",
            ("touches_authentication"): False,
            ("touches_authorization"): False,
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
        "CHANGES_REQUESTED\n\n"
        "## Findings\n"
        "- P1: Fix retry handling.\n"
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
    packet = parse_packet(_review_packet())

    validate_packet_for_task(
        packet,
        _task(status),
    )


def test_review_packet_rejects_non_review_state() -> None:
    packet = parse_packet(_review_packet())

    with pytest.raises(
        PacketError,
        match=("not waiting for an implementation review"),
    ):
        validate_packet_for_task(
            packet,
            _task(TaskStatus.READY_TO_RUN),
        )


def test_review_packet_requires_fingerprint() -> None:
    packet_text = _review_packet().replace(
        f'"review_fingerprint": "{"c" * 64}",',
        "",
    )

    packet = parse_packet(packet_text)

    with pytest.raises(
        PacketError,
        match=("implementation review must contain review_fingerprint"),
    ):
        validate_packet_for_task(
            packet,
            _task(TaskStatus.WAITING_FOR_REVIEW),
        )
