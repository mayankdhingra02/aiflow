from __future__ import annotations

import shlex
import shutil
import subprocess

from aiflow.errors import StateError
from aiflow.models import CodexRunSpec


def build_codex_command(spec: CodexRunSpec) -> list[str]:
    return [
        "codex",
        "exec",
        "--ignore-user-config",
        "-C",
        str(spec.repository_path),
        "-m",
        spec.model_id,
        "--config",
        f'model_reasoning_effort="{spec.reasoning_effort}"',
        "--sandbox",
        spec.sandbox,
        "--output-last-message",
        str(spec.report_path),
        "-",
    ]


def display_command(command: list[str]) -> str:
    return " \\\n  ".join(shlex.quote(part) for part in command)


def execute_codex(spec: CodexRunSpec) -> int:
    if not shutil.which("codex"):
        raise StateError("Codex CLI is not installed or is not on PATH")

    if not spec.prompt_path.exists():
        raise StateError(f"implementation prompt does not exist: {spec.prompt_path}")

    command = build_codex_command(spec)

    try:
        with spec.prompt_path.open("r", encoding="utf-8") as prompt:
            result = subprocess.run(
                command,
                stdin=prompt,
                cwd=spec.repository_path,
                check=False,
            )
    except OSError as exc:
        raise StateError(f"Codex could not be executed: {exc}") from exc

    return result.returncode
