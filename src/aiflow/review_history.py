from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from aiflow.db import Database
from aiflow.errors import StateError
from aiflow.history import (
    ensure_review_directory,
    review_directory,
    reviews_directory,
)
from aiflow.models import (
    ReviewHistoryRecord,
    TaskRecord,
)


@dataclass(frozen=True)
class ReviewArtifactPaths:
    sequence: int
    artifact_dir: Path
    fingerprint_path: Path
    evidence_path: Path
    prompt_path: Path
    packet_path: Path
    review_path: Path
    followup_prompt_path: Path


@dataclass(frozen=True)
class PreparedReview:
    record: ReviewHistoryRecord
    artifacts: ReviewArtifactPaths


def review_artifact_paths(
    task: TaskRecord,
    sequence: int,
) -> ReviewArtifactPaths:
    artifact_dir = review_directory(
        task,
        sequence,
    )

    return ReviewArtifactPaths(
        sequence=sequence,
        artifact_dir=artifact_dir,
        fingerprint_path=(artifact_dir / "review-fingerprint.txt"),
        evidence_path=(artifact_dir / "review-evidence.md"),
        prompt_path=(artifact_dir / "review-prompt.md"),
        packet_path=(artifact_dir / "review-packet.txt"),
        review_path=(artifact_dir / "review.md"),
        followup_prompt_path=(artifact_dir / "followup-implementation-prompt.md"),
    )


def _filesystem_review_sequences(
    task: TaskRecord,
) -> list[int]:
    directory = reviews_directory(task)

    if not directory.exists():
        return []

    try:
        entries = list(directory.iterdir())
    except OSError as exc:
        raise StateError(f"review history directory could not be read: {directory}") from exc

    sequences: list[int] = []

    for entry in entries:
        if not entry.is_dir():
            continue

        if not entry.name.isdigit():
            continue

        sequence = int(entry.name)

        if sequence < 1:
            continue

        sequences.append(sequence)

    return sequences


def next_review_sequence(
    *,
    db: Database,
    task: TaskRecord,
) -> int:
    database_sequence = db.next_review_sequence(task.id)

    filesystem_sequences = _filesystem_review_sequences(task)

    filesystem_sequence = max(filesystem_sequences) + 1 if filesystem_sequences else 1

    return max(
        database_sequence,
        filesystem_sequence,
    )


def preview_next_review_artifacts(
    *,
    db: Database,
    task: TaskRecord,
) -> ReviewArtifactPaths:
    sequence = next_review_sequence(
        db=db,
        task=task,
    )

    return review_artifact_paths(
        task,
        sequence,
    )


def allocate_review_directory(
    *,
    db: Database,
    task: TaskRecord,
) -> ReviewArtifactPaths:
    sequence = next_review_sequence(
        db=db,
        task=task,
    )

    artifacts = review_artifact_paths(
        task,
        sequence,
    )

    try:
        ensure_review_directory(
            task,
            sequence,
        )

    except FileExistsError as exc:
        raise StateError(
            f"review history directory already exists unexpectedly: {artifacts.artifact_dir}"
        ) from exc

    except OSError as exc:
        raise StateError(
            f"review history directory could not be created: {artifacts.artifact_dir}"
        ) from exc

    return artifacts


def record_prepared_review(
    *,
    db: Database,
    task: TaskRecord,
    artifacts: ReviewArtifactPaths,
    run_id: int | None,
    fingerprint: str,
) -> PreparedReview:
    record = db.create_review_history(
        task_id=task.id,
        sequence=artifacts.sequence,
        artifact_dir=(artifacts.artifact_dir),
        run_id=run_id,
        fingerprint=fingerprint,
    )

    return PreparedReview(
        record=record,
        artifacts=artifacts,
    )


def latest_prepared_review(
    *,
    db: Database,
    task: TaskRecord,
) -> PreparedReview | None:
    record = db.latest_review_history(task.id)

    if record is None:
        return None

    return PreparedReview(
        record=record,
        artifacts=review_artifact_paths(
            task,
            record.sequence,
        ),
    )


def get_review_by_sequence(
    *,
    db: Database,
    task: TaskRecord,
    sequence: int,
) -> PreparedReview | None:
    for record in db.list_review_history(task.id):
        if record.sequence != sequence:
            continue

        return PreparedReview(
            record=record,
            artifacts=review_artifact_paths(
                task,
                sequence,
            ),
        )

    return None
