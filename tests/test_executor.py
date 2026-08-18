from pathlib import Path
from subprocess import CompletedProcess

import pytest

from aiflow.errors import StateError
from aiflow.executor import (
    build_codex_command,
    execute_codex,
)
from aiflow.models import CodexRunSpec


def test_codex_command_uses_bounded_deterministic_configuration() -> None:
    spec = CodexRunSpec(
        repository_path=Path("/tmp/repo"),
        model_id="gpt-5.6-terra",
        reasoning_effort="medium",
        prompt_path=Path("/tmp/prompt.md"),
        report_path=Path("/tmp/report.md"),
    )

    command = build_codex_command(spec)

    assert "--ignore-user-config" in command
    assert "--json" in command
    assert "--sandbox" in command
    assert "workspace-write" in command
    assert "--output-last-message" in command
    assert "--yolo" not in command
    assert "--dangerously-bypass-approvals-and-sandbox" not in command


def test_execute_codex_wraps_process_oserror(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    prompt_path = tmp_path / "prompt.md"

    prompt_path.write_text(
        "Implement the task.",
        encoding="utf-8",
    )

    spec = CodexRunSpec(
        repository_path=tmp_path,
        model_id="gpt-5.6-terra",
        reasoning_effort="medium",
        prompt_path=prompt_path,
        report_path=(tmp_path / "report.md"),
    )

    monkeypatch.setattr(
        "aiflow.executor.shutil.which",
        lambda _command: "/usr/local/bin/codex",
    )

    def raise_oserror(
        *_args: object,
        **_kwargs: object,
    ) -> None:
        raise OSError("simulated launch failure")

    monkeypatch.setattr(
        "aiflow.executor.subprocess.run",
        raise_oserror,
    )

    with pytest.raises(
        StateError,
        match=("Codex could not be executed"),
    ):
        execute_codex(spec)


def test_execute_codex_captures_jsonl_events(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    prompt_path = tmp_path / "prompt.md"

    prompt_path.write_text(
        "Implement the task.",
        encoding="utf-8",
    )

    events_path = tmp_path / "events.jsonl"

    spec = CodexRunSpec(
        repository_path=tmp_path,
        model_id="gpt-5.6-terra",
        reasoning_effort="medium",
        prompt_path=prompt_path,
        report_path=(tmp_path / "report.md"),
    )

    monkeypatch.setattr(
        "aiflow.executor.shutil.which",
        lambda _command: "/usr/local/bin/codex",
    )

    def fake_run(
        command: list[str],
        **kwargs: object,
    ) -> CompletedProcess[str]:
        stdout = kwargs.get("stdout")

        assert stdout is not None

        stdout.write('{"type":"turn.started"}\n')
        stdout.write('{"type":"turn.completed","usage":{"input_tokens":10}}\n')

        return CompletedProcess(
            command,
            0,
        )

    monkeypatch.setattr(
        "aiflow.executor.subprocess.run",
        fake_run,
    )

    exit_code = execute_codex(
        spec,
        events_path=events_path,
    )

    assert exit_code == 0
    assert events_path.exists()

    contents = events_path.read_text(
        encoding="utf-8",
    )

    assert '"type":"turn.started"' in contents
    assert '"type":"turn.completed"' in contents
