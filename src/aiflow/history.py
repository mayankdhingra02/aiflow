from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from aiflow.models import TaskRecord

RUNS_DIRECTORY = "runs"
REVIEWS_DIRECTORY = "reviews"


@dataclass(frozen=True)
class LegacyRunArtifacts:
    implementation_prompt: Path
    implementation_report: Path
    codex_events: Path
    codex_event_summary: Path
    validation_summary: Path
    validation_directory: Path

    @property
    def present(self) -> bool:
        """
        Return True only when there is evidence that
        execution or validation actually occurred.

        implementation-prompt.md alone does not count:
        it is created before Codex execution.
        """
        return any(
            path.exists()
            for path in (
                self.implementation_report,
                self.codex_events,
                self.codex_event_summary,
                self.validation_summary,
                self.validation_directory,
            )
        )


@dataclass(frozen=True)
class LegacyReviewArtifacts:
    fingerprint: Path
    evidence: Path
    prompt: Path
    packet: Path
    review: Path
    followup_prompt: Path

    @property
    def present(self) -> bool:
        return any(
            path.exists()
            for path in (
                self.fingerprint,
                self.evidence,
                self.prompt,
                self.packet,
                self.review,
                self.followup_prompt,
            )
        )


def history_sequence_name(
    sequence: int,
) -> str:
    if sequence < 1:
        raise ValueError("history sequence must be positive")

    return f"{sequence:03d}"


def runs_directory(
    task: TaskRecord,
) -> Path:
    return task.task_dir / RUNS_DIRECTORY


def reviews_directory(
    task: TaskRecord,
) -> Path:
    return task.task_dir / REVIEWS_DIRECTORY


def run_directory(
    task: TaskRecord,
    sequence: int,
) -> Path:
    return runs_directory(task) / history_sequence_name(sequence)


def review_directory(
    task: TaskRecord,
    sequence: int,
) -> Path:
    return reviews_directory(task) / history_sequence_name(sequence)


def ensure_run_directory(
    task: TaskRecord,
    sequence: int,
) -> Path:
    path = run_directory(
        task,
        sequence,
    )

    path.mkdir(
        parents=True,
        exist_ok=False,
    )

    return path


def ensure_review_directory(
    task: TaskRecord,
    sequence: int,
) -> Path:
    path = review_directory(
        task,
        sequence,
    )

    path.mkdir(
        parents=True,
        exist_ok=False,
    )

    return path


def legacy_run_artifacts(
    task: TaskRecord,
) -> LegacyRunArtifacts:
    return LegacyRunArtifacts(
        implementation_prompt=(task.task_dir / "implementation-prompt.md"),
        implementation_report=(task.task_dir / "implementation-report.md"),
        codex_events=(task.task_dir / "codex-events.jsonl"),
        codex_event_summary=(task.task_dir / "codex-events-summary.json"),
        validation_summary=(task.task_dir / "validation-summary.json"),
        validation_directory=(task.task_dir / "validation"),
    )


def legacy_review_artifacts(
    task: TaskRecord,
) -> LegacyReviewArtifacts:
    return LegacyReviewArtifacts(
        fingerprint=(task.task_dir / "review-fingerprint.txt"),
        evidence=(task.task_dir / "review-evidence.md"),
        prompt=(task.task_dir / "review-prompt.md"),
        packet=(task.task_dir / "review-packet.txt"),
        review=(task.task_dir / "review.md"),
        followup_prompt=(task.task_dir / "followup-implementation-prompt.md"),
    )
