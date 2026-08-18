from __future__ import annotations

import hashlib
import json
import re

from pydantic import ValidationError

from aiflow.constants import PACKET_BODY_SEPARATOR, PACKET_END, PACKET_START
from aiflow.errors import PacketError
from aiflow.models import PacketEnvelope, ParsedPacket, TaskRecord


def _extract_packet_region(text: str) -> str:
    start_index = text.find(PACKET_START)
    if start_index < 0:
        raise PacketError(f"missing packet marker: {PACKET_START}")

    end_index = text.find(PACKET_END, start_index)
    if end_index < 0:
        raise PacketError(f"missing packet marker: {PACKET_END}")

    return text[start_index : end_index + len(PACKET_END)]


def parse_packet(text: str) -> ParsedPacket:
    raw = text.strip()
    if not raw:
        raise PacketError("clipboard or file content is empty")

    region = _extract_packet_region(raw)
    without_start = region[len(PACKET_START) :]
    if PACKET_BODY_SEPARATOR not in without_start:
        raise PacketError(f"missing packet separator: {PACKET_BODY_SEPARATOR}")

    envelope_text, body_and_end = without_start.split(PACKET_BODY_SEPARATOR, 1)
    body = body_and_end.rsplit(PACKET_END, 1)[0].strip()
    envelope_text = envelope_text.strip()

    # ChatGPT may place the JSON envelope in a fenced code block. Strip only the
    # fence lines; do not otherwise mutate the model-produced content.
    envelope_text = re.sub(r"^```(?:json)?\s*", "", envelope_text, flags=re.IGNORECASE)
    envelope_text = re.sub(r"\s*```$", "", envelope_text)

    try:
        payload = json.loads(envelope_text)
    except json.JSONDecodeError as exc:
        raise PacketError(f"packet envelope is not valid JSON: {exc.msg}") from exc

    try:
        envelope = PacketEnvelope.model_validate(payload)
    except ValidationError as exc:
        raise PacketError(f"packet envelope failed validation: {exc}") from exc

    if not body:
        raise PacketError("packet body is empty")

    digest = hashlib.sha256(region.encode("utf-8")).hexdigest()
    return ParsedPacket(envelope=envelope, body=body, raw_text=region, sha256=digest)


def validate_packet_for_task(packet: ParsedPacket, task: TaskRecord) -> None:
    envelope = packet.envelope
    failures: list[str] = []

    if envelope.task_id != task.id:
        failures.append(f"task_id mismatch: expected {task.id}, got {envelope.task_id}")
    if envelope.project_id != task.project_id:
        failures.append(
            f"project_id mismatch: expected {task.project_id}, got {envelope.project_id}"
        )
    if envelope.nonce != task.nonce:
        failures.append("nonce mismatch")
    if envelope.base_sha.lower() != task.base_sha.lower():
        failures.append(
            f"base_sha mismatch: expected {task.base_sha}, got {envelope.base_sha}"
        )

    if failures:
        raise PacketError("; ".join(failures))
