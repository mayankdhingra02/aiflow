from pathlib import Path

from aiflow.executor import build_codex_command
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
    assert "--sandbox" in command
    assert "workspace-write" in command
    assert "--yolo" not in command
    assert "--dangerously-bypass-approvals-and-sandbox" not in command
