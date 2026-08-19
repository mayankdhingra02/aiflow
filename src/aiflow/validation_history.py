from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from aiflow.errors import StateError

VALIDATIONS_DIRECTORY = "validations"


@dataclass(frozen=True)
class ValidationArtifactPaths:
    sequence: int
    artifact_dir: Path
    summary_path: Path
    logs_dir: Path


def validation_sequence_name(
    sequence: int,
) -> str:
    if sequence < 1:
        raise ValueError("validation sequence must be positive")

    return f"{sequence:03d}"


def validations_directory(
    base_artifact_dir: Path,
) -> Path:
    return base_artifact_dir / VALIDATIONS_DIRECTORY


def validation_attempt_directory(
    base_artifact_dir: Path,
    sequence: int,
) -> Path:
    return validations_directory(base_artifact_dir) / validation_sequence_name(sequence)


def validation_artifact_paths(
    base_artifact_dir: Path,
    sequence: int,
) -> ValidationArtifactPaths:
    artifact_dir = validation_attempt_directory(
        base_artifact_dir,
        sequence,
    )

    return ValidationArtifactPaths(
        sequence=sequence,
        artifact_dir=artifact_dir,
        summary_path=(artifact_dir / "validation-summary.json"),
        logs_dir=(artifact_dir / "validation"),
    )


def _validation_sequences(
    base_artifact_dir: Path,
) -> list[int]:
    directory = validations_directory(base_artifact_dir)

    if not directory.exists():
        return []

    sequences: list[int] = []

    try:
        entries = list(directory.iterdir())
    except OSError as exc:
        raise StateError(f"validation history directory could not be read: {directory}") from exc

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


def next_validation_sequence(
    base_artifact_dir: Path,
) -> int:
    sequences = _validation_sequences(base_artifact_dir)

    if not sequences:
        return 1

    return max(sequences) + 1


def allocate_validation_attempt(
    base_artifact_dir: Path,
) -> ValidationArtifactPaths:
    sequence = next_validation_sequence(base_artifact_dir)

    artifacts = validation_artifact_paths(
        base_artifact_dir,
        sequence,
    )

    try:
        artifacts.artifact_dir.mkdir(
            parents=True,
            exist_ok=False,
        )

    except FileExistsError as exc:
        raise StateError(
            f"validation history directory already exists unexpectedly: {artifacts.artifact_dir}"
        ) from exc

    except OSError as exc:
        raise StateError(
            f"validation history directory could not be created: {artifacts.artifact_dir}"
        ) from exc

    return artifacts


def latest_validation_artifacts(
    base_artifact_dir: Path,
) -> ValidationArtifactPaths | None:
    sequences = _validation_sequences(base_artifact_dir)

    if not sequences:
        return None

    return validation_artifact_paths(
        base_artifact_dir,
        max(sequences),
    )


def validation_summary_path_for_review(
    base_artifact_dir: Path,
) -> Path:
    latest = latest_validation_artifacts(base_artifact_dir)

    if latest is not None:
        return latest.summary_path

    # Backward compatibility for tasks that
    # existed before immutable validation
    # history was introduced.
    return base_artifact_dir / "validation-summary.json"
