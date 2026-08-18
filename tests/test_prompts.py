from __future__ import annotations

from pathlib import Path

from aiflow.models import ProjectRecord, TaskRecord, TaskStatus
from aiflow.prompts import build_planner_prompt


def test_planner_prompt_preserves_routing_identity() -> None:
    project = ProjectRecord(
        id="engineering-foundry",
        name="Engineering Foundry",
        path=Path("/repo"),
        remote_url="git@github.com:example/repo.git",
        created_at="2026-08-18T00:00:00+00:00",
        updated_at="2026-08-18T00:00:00+00:00",
    )
    task = TaskRecord(
        id="engineering-foundry-abcdef123456",
        project_id=project.id,
        title="Interview Playbook",
        request="Add Interview Playbook",
        status=TaskStatus.WAITING_FOR_PLAN,
        nonce="a" * 32,
        base_sha="b" * 40,
        branch="main",
        task_dir=Path("/tmp/task"),
        created_at="2026-08-18T00:00:00+00:00",
        updated_at="2026-08-18T00:00:00+00:00",
    )

    prompt = build_planner_prompt(
        project=project,
        task=task,
        repository_context="- app/page.tsx",
    )

    assert task.id in prompt
    assert task.nonce in prompt
    assert task.base_sha in prompt
    assert "AIFLOW_PACKET_V1" in prompt
    assert "gpt-5.6" not in prompt  # Planner chooses a role, not a hard-coded model ID.
