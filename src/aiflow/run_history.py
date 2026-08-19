from __future__ import annotations

import shutil
from dataclasses import dataclass
from pathlib import Path

from aiflow.db import Database
from aiflow.errors import StateError
from aiflow.history import (
    ensure_run_directory,
    run_directory,
)
from aiflow.models import (
    RunHistoryRecord,
    RunKind,
    TaskRecord,
)


@dataclass(frozen=True)
class RunArtifactPaths:
    artifact_dir: Path
    prompt_path: Path
    report_path: Path
    events_path: Path
    codex_summary_path: Path


@dataclass(frozen=True)
class AllocatedRun:
    record: RunHistoryRecord
    artifacts: RunArtifactPaths


def run_artifact_paths(
    task: TaskRecord,
    sequence: int,
) -> RunArtifactPaths:
    artifact_dir = run_directory(
        task,
        sequence,
    )

    return RunArtifactPaths(
        artifact_dir=artifact_dir,
        prompt_path=(artifact_dir / "implementation-prompt.md"),
        report_path=(artifact_dir / "implementation-report.md"),
        events_path=(artifact_dir / "codex-events.jsonl"),
        codex_summary_path=(artifact_dir / "codex-events-summary.json"),
    )


def preview_next_run_artifacts(
    *,
    db: Database,
    task: TaskRecord,
) -> RunArtifactPaths:
    sequence = db.next_run_sequence(task.id)

    return run_artifact_paths(
        task,
        sequence,
    )


def allocate_run(
    *,
    db: Database,
    task: TaskRecord,
    kind: RunKind,
    source_prompt_path: Path,
    model_role: str,
    reasoning_effort: str,
) -> AllocatedRun:
    try:
        prompt_text = source_prompt_path.read_text(encoding="utf-8")

    except OSError as exc:
        raise StateError(f"implementation prompt could not be read: {source_prompt_path}") from exc

    sequence = db.next_run_sequence(task.id)

    artifacts = run_artifact_paths(
        task,
        sequence,
    )

    try:
        ensure_run_directory(
            task,
            sequence,
        )

    except FileExistsError as exc:
        raise StateError(
            f"run history directory already exists unexpectedly: {artifacts.artifact_dir}"
        ) from exc

    except OSError as exc:
        raise StateError(
            f"run history directory could not be created: {artifacts.artifact_dir}"
        ) from exc

    try:
        artifacts.prompt_path.write_text(
            prompt_text,
            encoding="utf-8",
        )

        record = db.create_run_history(
            task_id=task.id,
            sequence=sequence,
            kind=kind,
            artifact_dir=(artifacts.artifact_dir),
            model_role=model_role,
            reasoning_effort=(reasoning_effort),
        )

    except Exception as exc:
        shutil.rmtree(
            artifacts.artifact_dir,
            ignore_errors=True,
        )

        if isinstance(
            exc,
            StateError,
        ):
            raise

        raise StateError("run history could not be allocated") from exc

    return AllocatedRun(
        record=record,
        artifacts=artifacts,
    )
