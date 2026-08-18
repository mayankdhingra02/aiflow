from __future__ import annotations

import json
from pathlib import Path

import pytest

from aiflow.constants import PACKET_BODY_SEPARATOR, PACKET_END, PACKET_START
from aiflow.errors import PacketError
from aiflow.models import TaskRecord, TaskStatus
from aiflow.packets import parse_packet, validate_packet_for_task


def _payload() -> dict[str, object]:
    return {
        "packet_version": 1,
        "packet_id": "packet-12345678",
        "project_id": "engineering-foundry",
        "task_id": "engineering-foundry-abcdef123456",
        "nonce": "0123456789abcdef0123456789abcdef",
        "stage": "implementation_plan",
        "base_sha": "a" * 40,
        "execution": {
            "model_role": "terra",
            "reasoning_effort": "high",
        },
        "risk": {
            "level": "medium",
            "touches_authentication": False,
            "touches_authorization": False,
            "touches_database": False,
            "destructive_change": False,
            "touches_secrets": False,
            "touches_production_infrastructure": False,
        },
        "requires_human_approval_before_execution": False,
    }


def _packet(payload: dict[str, object] | None = None) -> str:
    payload = payload or _payload()
    return (
        f"Some optional prose\n{PACKET_START}\n```json\n{json.dumps(payload)}\n```\n"
        f"{PACKET_BODY_SEPARATOR}\n# Plan\nDo the work.\n{PACKET_END}\n"
    )


def _task() -> TaskRecord:
    return TaskRecord(
        id="engineering-foundry-abcdef123456",
        project_id="engineering-foundry",
        title="Interview Playbook",
        request="Add Interview Playbook",
        status=TaskStatus.WAITING_FOR_PLAN,
        nonce="0123456789abcdef0123456789abcdef",
        base_sha="a" * 40,
        branch="main",
        task_dir=Path("/tmp/task"),
        created_at="2026-08-18T00:00:00+00:00",
        updated_at="2026-08-18T00:00:00+00:00",
    )


def test_parse_packet_accepts_fenced_json() -> None:
    parsed = parse_packet(_packet())
    assert parsed.envelope.execution.model_role.value == "terra"
    assert parsed.body.startswith("# Plan")
    assert len(parsed.sha256) == 64


def test_parse_packet_rejects_missing_marker() -> None:
    with pytest.raises(PacketError, match="missing packet marker"):
        parse_packet("not a packet")


def test_validate_packet_for_task_rejects_nonce_mismatch() -> None:
    payload = _payload()
    payload["nonce"] = "f" * 32
    parsed = parse_packet(_packet(payload))
    with pytest.raises(PacketError, match="nonce mismatch"):
        validate_packet_for_task(parsed, _task())


def test_validate_packet_rejects_plan_for_task_that_already_has_plan() -> None:
    parsed = parse_packet(_packet())
    task = _task().model_copy(update={"status": TaskStatus.READY_TO_RUN})

    with pytest.raises(
        PacketError,
        match="not waiting for an implementation plan",
    ):
        validate_packet_for_task(parsed, task)
