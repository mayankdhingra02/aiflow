from pathlib import Path

import pytest

from aiflow.errors import PacketError
from aiflow.models import (
    ProjectRecord,
    TaskRecord,
    TaskStatus,
)
from aiflow.review_loop import (
    ReviewVerdict,
    build_followup_implementation_prompt,
    parse_review_verdict,
)


def _task() -> TaskRecord:
    return TaskRecord(
        id="demo-review-1234",
        project_id="demo",
        title="Demo",
        request="Implement the feature.",
        status=(TaskStatus.WAITING_FOR_REVIEW),
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=Path("/tmp/task"),
        created_at=("2026-08-18T00:00:00+00:00"),
        updated_at=("2026-08-18T00:00:00+00:00"),
    )


def _project() -> ProjectRecord:
    return ProjectRecord(
        id="demo",
        name="Demo",
        path=Path("/tmp/repo"),
        remote_url=None,
        created_at=("2026-08-18T00:00:00+00:00"),
        updated_at=("2026-08-18T00:00:00+00:00"),
    )


def test_parse_ship_verdict() -> None:
    body = """
# Implementation Review

## Verdict
SHIP

## Findings
None.
""".strip()

    assert parse_review_verdict(body) == ReviewVerdict.SHIP


def test_parse_changes_requested_verdict() -> None:
    body = """
# Implementation Review

## Verdict
CHANGES_REQUESTED

## Findings
- P1: Fix the retry path.
""".strip()

    assert parse_review_verdict(body) == ReviewVerdict.CHANGES_REQUESTED


def test_review_verdict_rejects_unknown_value() -> None:
    body = """
# Implementation Review

## Verdict
MAYBE

## Findings
None.
""".strip()

    with pytest.raises(
        PacketError,
        match=("must be exactly SHIP or CHANGES_REQUESTED"),
    ):
        parse_review_verdict(body)


def test_review_verdict_rejects_ambiguity() -> None:
    body = """
# Implementation Review

## Verdict
SHIP

## Findings
CHANGES_REQUESTED
""".strip()

    with pytest.raises(
        PacketError,
        match="ambiguous",
    ):
        parse_review_verdict(body)


def test_followup_prompt_contains_review_and_scope_guards() -> None:
    prompt = build_followup_implementation_prompt(
        project=_project(),
        task=_task(),
        plan_body=("# Implementation Plan\nImplement the feature."),
        review_body=(
            "# Implementation Review\n\n"
            "## Verdict\n"
            "CHANGES_REQUESTED\n\n"
            "## Findings\n"
            "- P1: Fix retry behavior."
        ),
    )

    assert "Fix retry behavior." in prompt

    assert "Preserve correct existing work." in prompt

    assert "Do not reset or discard" in prompt

    assert "Implement the feature." in prompt
