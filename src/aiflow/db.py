from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from aiflow.models import ProjectRecord, TaskRecord, TaskStatus
from aiflow.paths import database_path


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


class Database:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or database_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.initialize()

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        try:
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def initialize(self) -> None:
        with self.connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    remote_url TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    request TEXT NOT NULL,
                    status TEXT NOT NULL,
                    nonce TEXT NOT NULL,
                    base_sha TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    task_dir TEXT NOT NULL,
                    plan_path TEXT,
                    recommended_model TEXT,
                    reasoning_effort TEXT,
                    risk_level TEXT,
                    requires_human_approval INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS packets (
                    packet_id TEXT PRIMARY KEY,
                    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                    stage TEXT NOT NULL,
                    sha256 TEXT NOT NULL,
                    received_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id);
                CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
                """
            )

    def upsert_project(
        self,
        *,
        project_id: str,
        name: str,
        path: Path,
        remote_url: str | None,
    ) -> ProjectRecord:
        now = utc_now()
        resolved_path = str(path.resolve())
        persisted_project_id = project_id
        with self.connect() as connection:
            existing_path = connection.execute(
                "SELECT id FROM projects WHERE path = ?",
                (resolved_path,),
            ).fetchone()
            if existing_path is not None:
                persisted_project_id = str(existing_path["id"])
                connection.execute(
                    """
                    UPDATE projects
                    SET name = ?, remote_url = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (name, remote_url, now, persisted_project_id),
                )
            else:
                connection.execute(
                    """
                    INSERT INTO projects (id, name, path, remote_url, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        path = excluded.path,
                        remote_url = excluded.remote_url,
                        updated_at = excluded.updated_at
                    """,
                    (project_id, name, resolved_path, remote_url, now, now),
                )
        project = self.get_project(persisted_project_id)
        assert project is not None
        return project

    def get_project(self, project_id: str) -> ProjectRecord | None:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT * FROM projects WHERE id = ?",
                (project_id,),
            ).fetchone()
        if row is None:
            return None
        return ProjectRecord(**dict(row))

    def get_project_by_path(self, path: Path) -> ProjectRecord | None:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT * FROM projects WHERE path = ?",
                (str(path.resolve()),),
            ).fetchone()
        if row is None:
            return None
        return ProjectRecord(**dict(row))

    def list_projects(self) -> list[ProjectRecord]:
        with self.connect() as connection:
            rows = connection.execute("SELECT * FROM projects ORDER BY updated_at DESC").fetchall()
        return [ProjectRecord(**dict(row)) for row in rows]

    def create_task(
        self,
        *,
        task_id: str,
        project_id: str,
        title: str,
        request: str,
        nonce: str,
        base_sha: str,
        branch: str,
        task_dir: Path,
    ) -> TaskRecord:
        now = utc_now()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO tasks (
                    id, project_id, title, request, status, nonce, base_sha, branch,
                    task_dir, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    task_id,
                    project_id,
                    title,
                    request,
                    TaskStatus.WAITING_FOR_PLAN.value,
                    nonce,
                    base_sha,
                    branch,
                    str(task_dir),
                    now,
                    now,
                ),
            )
        task = self.get_task(task_id)
        assert task is not None
        return task

    def get_task(self, task_id: str) -> TaskRecord | None:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT * FROM tasks WHERE id = ?",
                (task_id,),
            ).fetchone()
        if row is None:
            return None
        return TaskRecord(**dict(row))

    def list_tasks(self, *, limit: int = 20) -> list[TaskRecord]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM tasks ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [TaskRecord(**dict(row)) for row in rows]

    def update_task_plan(
        self,
        *,
        task_id: str,
        plan_path: Path,
        recommended_model: str,
        reasoning_effort: str,
        risk_level: str,
        requires_human_approval: bool,
    ) -> None:
        with self.connect() as connection:
            connection.execute(
                """
                UPDATE tasks
                SET status = ?, plan_path = ?, recommended_model = ?, reasoning_effort = ?,
                    risk_level = ?, requires_human_approval = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    TaskStatus.READY_TO_RUN.value,
                    str(plan_path),
                    recommended_model,
                    reasoning_effort,
                    risk_level,
                    int(requires_human_approval),
                    utc_now(),
                    task_id,
                ),
            )

    def update_task_followup(
        self,
        *,
        task_id: str,
        recommended_model: str,
        reasoning_effort: str,
        risk_level: str,
        requires_human_approval: bool,
    ) -> None:
        with self.connect() as connection:
            connection.execute(
                """
                UPDATE tasks
                SET status = ?,
                    recommended_model = ?,
                    reasoning_effort = ?,
                    risk_level = ?,
                    requires_human_approval = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                (
                    TaskStatus.REVIEW_IMPORTED.value,
                    recommended_model,
                    reasoning_effort,
                    risk_level,
                    int(requires_human_approval),
                    utc_now(),
                    task_id,
                ),
            )

    def update_task_status(
        self,
        *,
        task_id: str,
        status: TaskStatus,
    ) -> None:
        with self.connect() as connection:
            connection.execute(
                """
                UPDATE tasks
                SET status = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    status.value,
                    utc_now(),
                    task_id,
                ),
            )

    def packet_exists(self, packet_id: str) -> bool:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT 1 FROM packets WHERE packet_id = ?",
                (packet_id,),
            ).fetchone()
        return row is not None

    def record_packet(self, *, packet_id: str, task_id: str, stage: str, sha256: str) -> None:
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO packets (packet_id, task_id, stage, sha256, received_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (packet_id, task_id, stage, sha256, utc_now()),
            )
