from __future__ import annotations

import os
import sys
from pathlib import Path


def app_home() -> Path:
    """Return the directory used for Aiflow state.

    AIFLOW_HOME is supported to make tests and portable installations easy.
    """
    override = os.getenv("AIFLOW_HOME")
    if override:
        return Path(override).expanduser().resolve()

    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Aiflow"

    if os.name == "nt":
        appdata = os.getenv("LOCALAPPDATA")
        if appdata:
            return Path(appdata) / "Aiflow"

    return Path.home() / ".local" / "share" / "aiflow"


def ensure_app_dirs() -> Path:
    home = app_home()
    (home / "tasks").mkdir(parents=True, exist_ok=True)
    (home / "logs").mkdir(parents=True, exist_ok=True)
    return home


def database_path() -> Path:
    return ensure_app_dirs() / "aiflow.db"


def task_directory(task_id: str) -> Path:
    path = ensure_app_dirs() / "tasks" / task_id
    path.mkdir(parents=True, exist_ok=True)
    return path
