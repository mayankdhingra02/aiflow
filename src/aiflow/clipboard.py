from __future__ import annotations

import shutil
import subprocess

from aiflow.errors import ClipboardError


def _run(command: list[str], *, input_text: str | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            input=input_text,
            text=True,
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ClipboardError(f"clipboard command failed: {' '.join(command)}") from exc
    return result.stdout


def copy_text(text: str) -> None:
    if shutil.which("pbcopy"):
        _run(["pbcopy"], input_text=text)
        return
    raise ClipboardError("pbcopy was not found; clipboard support currently requires macOS")


def paste_text() -> str:
    if shutil.which("pbpaste"):
        return _run(["pbpaste"])
    raise ClipboardError("pbpaste was not found; clipboard support currently requires macOS")
