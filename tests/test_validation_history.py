from pathlib import Path

from aiflow.validation_history import (
    allocate_validation_attempt,
    latest_validation_artifacts,
    next_validation_sequence,
    validation_summary_path_for_review,
)


def test_first_validation_attempt_is_001(
    tmp_path: Path,
) -> None:
    base = tmp_path / "run"

    attempt = allocate_validation_attempt(base)

    assert attempt.sequence == 1

    assert attempt.artifact_dir == base / "validations" / "001"

    assert next_validation_sequence(base) == 2


def test_validation_attempts_are_immutable(
    tmp_path: Path,
) -> None:
    base = tmp_path / "run"

    first = allocate_validation_attempt(base)

    first.summary_path.write_text(
        "first\n",
        encoding="utf-8",
    )

    second = allocate_validation_attempt(base)

    second.summary_path.write_text(
        "second\n",
        encoding="utf-8",
    )

    assert first.sequence == 1
    assert second.sequence == 2

    assert first.summary_path.read_text(encoding="utf-8") == "first\n"

    assert second.summary_path.read_text(encoding="utf-8") == "second\n"


def test_latest_validation_is_selected(
    tmp_path: Path,
) -> None:
    base = tmp_path / "run"

    first = allocate_validation_attempt(base)

    second = allocate_validation_attempt(base)

    latest = latest_validation_artifacts(base)

    assert latest is not None

    assert latest.artifact_dir == second.artifact_dir

    assert latest.artifact_dir != first.artifact_dir


def test_review_summary_uses_legacy_fallback(
    tmp_path: Path,
) -> None:
    base = tmp_path / "legacy"

    base.mkdir()

    legacy = base / "validation-summary.json"

    legacy.write_text(
        "{}\n",
        encoding="utf-8",
    )

    assert validation_summary_path_for_review(base) == legacy

    attempt = allocate_validation_attempt(base)

    attempt.summary_path.write_text(
        '{"new": true}\n',
        encoding="utf-8",
    )

    assert validation_summary_path_for_review(base) == attempt.summary_path
