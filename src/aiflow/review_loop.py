from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from textwrap import dedent

from aiflow.db import Database
from aiflow.errors import (
    PacketError,
    StateError,
)
from aiflow.git import (
    validate_repository_state,
)
from aiflow.models import (
    PacketStage,
    ParsedPacket,
    ProjectRecord,
    TaskRecord,
    TaskStatus,
)
from aiflow.packets import (
    validate_packet_for_task,
)
from aiflow.review import (
    compute_worktree_fingerprint,
)


class ReviewVerdict(StrEnum):
    SHIP = "SHIP"
    CHANGES_REQUESTED = "CHANGES_REQUESTED"


@dataclass(frozen=True)
class ReviewImportResult:
    verdict: ReviewVerdict
    review_path: Path
    raw_packet_path: Path
    followup_prompt_path: Path | None
    review_fingerprint: str
    requires_human_approval: bool


def parse_review_verdict(
    body: str,
) -> ReviewVerdict:
    lines = body.splitlines()

    nonempty = [line.strip() for line in lines if line.strip()]

    if not nonempty:
        raise PacketError("review body is empty")

    if nonempty[0] != "# Implementation Review":
        raise PacketError("review body must begin with '# Implementation Review'")

    verdict_headings = [index for index, line in enumerate(lines) if line.strip() == "## Verdict"]

    if len(verdict_headings) != 1:
        raise PacketError("review body must contain exactly one '## Verdict' section")

    heading_index = verdict_headings[0]

    verdict_index: int | None = None

    for index in range(
        heading_index + 1,
        len(lines),
    ):
        value = lines[index].strip()

        if not value:
            continue

        verdict_index = index
        break

    if verdict_index is None:
        raise PacketError("review verdict is missing")

    verdict_text = lines[verdict_index].strip()

    try:
        verdict = ReviewVerdict(verdict_text)
    except ValueError as exc:
        raise PacketError("review verdict must be exactly SHIP or CHANGES_REQUESTED") from exc

    allowed_verdicts = {verdict.value for verdict in ReviewVerdict}

    for index, line in enumerate(lines):
        if index == verdict_index:
            continue

        if line.strip() in allowed_verdicts:
            raise PacketError("review body contains an ambiguous additional verdict")

    return verdict


def build_followup_implementation_prompt(
    *,
    project: ProjectRecord,
    task: TaskRecord,
    plan_body: str,
    review_body: str,
) -> str:
    return dedent(
        f"""
        Implement the requested fixes from the imported Aiflow review.

        ## Trusted execution context

        - Project: {project.name}
        - Project ID: {project.id}
        - Task ID: {task.id}
        - Original approved base commit: {task.base_sha}
        - Branch: {task.branch}

        This is a follow-up implementation pass.

        The current working tree contains the implementation that was reviewed.
        Preserve correct existing work. Do not reset or discard the reviewed
        implementation merely to return to the original base commit.

        Apply only the changes needed to resolve the substantive review findings.
        Do not broaden scope.

        Do not push, merge, commit, rewrite public history, expose secrets, weaken
        tests, or use danger-full-access.

        If a review finding conflicts with the repository or cannot be resolved
        safely without credentials, destructive operations, or production access,
        stop and report the conflict instead of guessing.

        Run directly relevant validation. Never claim a command passed unless it
        actually ran.

        Finish with:
        1. changed files,
        2. review findings addressed,
        3. tests and validation commands run,
        4. unresolved findings or risks,
        5. current Git status.

        ## Original user request

        {task.request}

        ## Original approved implementation plan

        {plan_body}

        ## Imported implementation review

        {review_body}
        """
    ).strip()


def followup_prompt_path(
    task: TaskRecord,
) -> Path:
    return task.task_dir / "followup-implementation-prompt.md"


def review_fingerprint_path(
    task: TaskRecord,
) -> Path:
    return task.task_dir / "review-fingerprint.txt"


def is_followup_execution(
    task: TaskRecord,
) -> bool:
    if task.status == TaskStatus.REVIEW_IMPORTED:
        return True

    return (
        task.status == TaskStatus.FAILED
        and followup_prompt_path(task).exists()
        and review_fingerprint_path(task).exists()
    )


def validate_followup_worktree(
    *,
    project: ProjectRecord,
    task: TaskRecord,
) -> str:
    validate_repository_state(
        project.path,
        expected_sha=task.base_sha,
        expected_branch=task.branch,
        require_clean=False,
    )

    fingerprint_file = review_fingerprint_path(task)

    if not fingerprint_file.exists():
        raise StateError("follow-up review fingerprint is missing")

    try:
        expected = fingerprint_file.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise StateError("follow-up review fingerprint could not be read") from exc

    if len(expected) != 64:
        raise StateError("follow-up review fingerprint is invalid")

    current = compute_worktree_fingerprint(project.path)

    if current != expected:
        raise StateError(
            "working tree changed after the "
            "Sol review was imported; restore "
            "the reviewed state or prepare a "
            "new review"
        )

    return current


def _packet_requires_confirmation(
    packet: ParsedPacket,
) -> bool:
    return (
        packet.envelope.requires_human_approval_before_execution
        or packet.envelope.risk.requires_confirmation
        or (packet.envelope.execution.model_role.value == "sol")
        or (packet.envelope.execution.reasoning_effort.value == "xhigh")
    )


def import_review_packet(
    *,
    db: Database,
    project: ProjectRecord,
    task: TaskRecord,
    packet: ParsedPacket,
) -> ReviewImportResult:
    if packet.envelope.stage != PacketStage.IMPLEMENTATION_REVIEW:
        raise PacketError("expected an implementation_review packet")

    validate_packet_for_task(
        packet,
        task,
    )

    if db.packet_exists(packet.envelope.packet_id):
        raise PacketError(f"packet has already been processed: {packet.envelope.packet_id}")

    review_fingerprint = packet.envelope.review_fingerprint

    if not review_fingerprint:
        raise PacketError("implementation review packet is missing review_fingerprint")

    validate_repository_state(
        project.path,
        expected_sha=task.base_sha,
        expected_branch=task.branch,
        require_clean=False,
    )

    current_fingerprint = compute_worktree_fingerprint(project.path)

    if current_fingerprint != review_fingerprint:
        raise PacketError(
            "review packet is stale: the "
            "current working tree no longer "
            "matches the worktree reviewed "
            "by Sol"
        )

    verdict = parse_review_verdict(packet.body)

    task.task_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    review_path = task.task_dir / "review.md"

    raw_packet_path = task.task_dir / "review-packet.txt"

    fingerprint_path = review_fingerprint_path(task)

    review_path.write_text(
        packet.body + "\n",
        encoding="utf-8",
    )

    raw_packet_path.write_text(
        packet.raw_text + "\n",
        encoding="utf-8",
    )

    fingerprint_path.write_text(
        review_fingerprint + "\n",
        encoding="utf-8",
    )

    followup_path: Path | None = None

    if verdict == ReviewVerdict.CHANGES_REQUESTED:
        plan_path = task.plan_path or task.task_dir / "plan.md"

        try:
            plan_body = plan_path.read_text(encoding="utf-8")
        except OSError as exc:
            raise StateError("approved implementation plan could not be read") from exc

        followup_path = followup_prompt_path(task)

        followup_path.write_text(
            build_followup_implementation_prompt(
                project=project,
                task=task,
                plan_body=plan_body,
                review_body=packet.body,
            ),
            encoding="utf-8",
        )

    db.record_packet(
        packet_id=(packet.envelope.packet_id),
        task_id=task.id,
        stage=(packet.envelope.stage.value),
        sha256=packet.sha256,
    )

    needs_confirmation = _packet_requires_confirmation(packet)

    if verdict == ReviewVerdict.SHIP:
        db.update_task_status(
            task_id=task.id,
            status=TaskStatus.COMPLETED,
        )

    else:
        db.update_task_followup(
            task_id=task.id,
            recommended_model=(packet.envelope.execution.model_role.value),
            reasoning_effort=(packet.envelope.execution.reasoning_effort.value),
            risk_level=(packet.envelope.risk.level),
            requires_human_approval=(needs_confirmation),
        )

    return ReviewImportResult(
        verdict=verdict,
        review_path=review_path,
        raw_packet_path=raw_packet_path,
        followup_prompt_path=(followup_path),
        review_fingerprint=(review_fingerprint),
        requires_human_approval=(needs_confirmation),
    )
