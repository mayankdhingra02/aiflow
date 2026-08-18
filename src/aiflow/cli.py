from __future__ import annotations

import secrets
import shutil
import sys
import uuid
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from aiflow import __version__
from aiflow.clipboard import copy_text, paste_text
from aiflow.constants import MODEL_BY_ROLE
from aiflow.db import Database
from aiflow.errors import AiflowError, PacketError, StateError
from aiflow.executor import build_codex_command, display_command, execute_codex
from aiflow.git import (
    inspect_repository,
    repository_context,
    validate_repository_state,
)
from aiflow.models import CodexRunSpec, PacketStage, TaskStatus
from aiflow.packets import parse_packet, validate_packet_for_task
from aiflow.paths import app_home, task_directory
from aiflow.prompts import build_implementation_prompt, build_planner_prompt

app = typer.Typer(
    name="aiflow",
    help="Route ChatGPT Web plans into safe, project-specific Codex runs.",
    no_args_is_help=True,
)
console = Console()


def _db() -> Database:
    return Database()


def _fail(message: str, code: int = 1) -> None:
    console.print(f"[bold red]Error:[/bold red] {message}")
    raise typer.Exit(code)


def _current_project(db: Database, path: Path) -> tuple[object, object]:
    facts = inspect_repository(path)
    project = db.get_project_by_path(facts.root)
    if project is None:
        project = db.upsert_project(
            project_id=facts.project_id,
            name=facts.name,
            path=facts.root,
            remote_url=facts.remote_url,
        )
    return project, facts


@app.command()
def version() -> None:
    """Print the installed Aiflow version."""
    console.print(__version__)


@app.command()
def doctor() -> None:
    """Check local dependencies and state paths."""
    checks = [
        ("Python >= 3.11", sys.version_info >= (3, 11), sys.version.split()[0]),
        ("git", bool(shutil.which("git")), shutil.which("git") or "not found"),
        ("pbcopy", bool(shutil.which("pbcopy")), shutil.which("pbcopy") or "not found"),
        ("pbpaste", bool(shutil.which("pbpaste")), shutil.which("pbpaste") or "not found"),
        ("codex", bool(shutil.which("codex")), shutil.which("codex") or "not found"),
    ]

    table = Table(title="Aiflow doctor")
    table.add_column("Check")
    table.add_column("Status")
    table.add_column("Detail")
    for name, ok, detail in checks:
        table.add_row(
            name,
            "[green]OK[/green]" if ok else "[yellow]Missing[/yellow]",
            str(detail),
        )
    table.add_row("AIFLOW_HOME", "[green]Ready[/green]", str(app_home()))
    console.print(table)


@app.command()
def register(
    path: Annotated[
        Path | None,
        typer.Argument(
            exists=True,
            file_okay=False,
            resolve_path=True,
        ),
    ] = None,
    name: Annotated[
        str | None,
        typer.Option(
            "--name",
            help="Override the display name.",
        ),
    ] = None,
) -> None:
    """Register a Git repository as an Aiflow project."""
    path = path or Path.cwd()

    try:
        facts = inspect_repository(path)
        db = _db()
        project = db.upsert_project(
            project_id=facts.project_id,
            name=name or facts.name,
            path=facts.root,
            remote_url=facts.remote_url,
        )
    except AiflowError as exc:
        _fail(str(exc))

    console.print(
        Panel.fit(
            f"[bold green]Registered[/bold green]\n"
            f"Project: {project.name}\n"
            f"ID: {project.id}\n"
            f"Path: {project.path}\n"
            f"Remote: {project.remote_url or 'none'}",
            title="Aiflow",
        )
    )


@app.command("projects")
def list_projects() -> None:
    """List registered projects."""
    projects = _db().list_projects()
    if not projects:
        console.print(
            "No projects are registered. Run [bold]aiflow register[/bold] in a repository."
        )
        return

    table = Table(title="Registered projects")
    table.add_column("ID")
    table.add_column("Name")
    table.add_column("Path")
    table.add_column("Remote")
    for project in projects:
        table.add_row(
            project.id,
            project.name,
            str(project.path),
            project.remote_url or "—",
        )
    console.print(table)


@app.command()
def start(
    request: Annotated[
        str,
        typer.Argument(help="Describe the software change to plan."),
    ],
    path: Annotated[
        Path | None,
        typer.Option(
            "--path",
            exists=True,
            file_okay=False,
            resolve_path=True,
        ),
    ] = None,
    copy: Annotated[
        bool,
        typer.Option(
            "--copy/--no-copy",
            help="Copy the Sol planning prompt.",
        ),
    ] = True,
) -> None:
    """Create a task and generate the ChatGPT Web Sol planning prompt."""
    path = path or Path.cwd()

    try:
        db = _db()
        project, facts = _current_project(db, path)
        if facts.dirty:
            raise StateError(
                "the repository has uncommitted changes; "
                "commit or stash them before starting an Aiflow task"
            )

        normalized_request = request.strip()
        if not normalized_request:
            raise StateError("task request cannot be empty")

        task_id = f"{project.id}-{uuid.uuid4().hex[:12]}"
        nonce = secrets.token_hex(16)
        task_dir = task_directory(task_id)
        title = normalized_request.splitlines()[0][:100]
        task = db.create_task(
            task_id=task_id,
            project_id=project.id,
            title=title,
            request=normalized_request,
            nonce=nonce,
            base_sha=facts.head_sha,
            branch=facts.branch,
            task_dir=task_dir,
        )

        context = repository_context(facts.root)
        prompt = build_planner_prompt(
            project=project,
            task=task,
            repository_context=context,
        )
        prompt_path = task_dir / "planner-prompt.md"
        request_path = task_dir / "request.md"
        prompt_path.write_text(prompt, encoding="utf-8")
        request_path.write_text(normalized_request + "\n", encoding="utf-8")
        if copy:
            copy_text(prompt)
    except AiflowError as exc:
        _fail(str(exc))

    next_step = (
        "The planning prompt is on your clipboard.\n"
        "1. Paste it into ChatGPT Web using Sol.\n"
        "2. Copy the final AIFLOW_PACKET_V1 response.\n"
        "3. Run: aiflow import-packet --clipboard"
        if copy
        else f"Open and copy: {prompt_path}"
    )
    console.print(
        Panel.fit(
            f"[bold green]Task created[/bold green]\n"
            f"Project: {project.name}\n"
            f"Task ID: {task.id}\n"
            f"Base SHA: {task.base_sha}\n"
            f"Task files: {task.task_dir}\n\n"
            f"{next_step}",
            title="Waiting for Sol plan",
        )
    )


@app.command("tasks")
def list_tasks(
    limit: Annotated[
        int,
        typer.Option(
            min=1,
            max=200,
            help="Maximum number of recent tasks to show.",
        ),
    ] = 20,
) -> None:
    """List recent tasks."""
    tasks = _db().list_tasks(limit=limit)
    if not tasks:
        console.print("No tasks have been created.")
        return

    table = Table(title="Recent Aiflow tasks")
    table.add_column("Task ID")
    table.add_column("Project")
    table.add_column("Status")
    table.add_column("Model")
    table.add_column("Title")
    for task in tasks:
        model = task.recommended_model or "—"
        if task.reasoning_effort:
            model = f"{model} / {task.reasoning_effort}"
        table.add_row(
            task.id,
            task.project_id,
            task.status.value,
            model,
            task.title,
        )
    console.print(table)


@app.command("import-packet")
def import_packet(
    clipboard: Annotated[
        bool,
        typer.Option(
            "--clipboard",
            help="Read the packet from the clipboard.",
        ),
    ] = False,
    file: Annotated[
        Path | None,
        typer.Option(
            "--file",
            exists=True,
            dir_okay=False,
            resolve_path=True,
        ),
    ] = None,
) -> None:
    """Validate and import a copied Sol plan packet."""
    if clipboard == (file is not None):
        _fail("choose exactly one source: --clipboard or --file")

    try:
        text = (
            paste_text() if clipboard else file.read_text(encoding="utf-8")  # type: ignore[union-attr]
        )
        packet = parse_packet(text)
        if packet.envelope.stage != PacketStage.IMPLEMENTATION_PLAN:
            raise PacketError(
                "this command currently accepts implementation_plan packets, "
                f"got {packet.envelope.stage}"
            )

        db = _db()
        task = db.get_task(packet.envelope.task_id)
        if task is None:
            raise PacketError(f"unknown task ID: {packet.envelope.task_id}")
        validate_packet_for_task(packet, task)
        if db.packet_exists(packet.envelope.packet_id):
            raise PacketError(f"packet has already been processed: {packet.envelope.packet_id}")

        project = db.get_project(task.project_id)
        if project is None:
            raise StateError(f"project no longer exists: {task.project_id}")

        validate_repository_state(
            project.path,
            expected_sha=task.base_sha,
            expected_branch=task.branch,
        )

        plan_path = task.task_dir / "plan.md"
        raw_packet_path = task.task_dir / "plan-packet.txt"
        implementation_prompt_path = task.task_dir / "implementation-prompt.md"
        plan_path.write_text(packet.body + "\n", encoding="utf-8")
        raw_packet_path.write_text(packet.raw_text + "\n", encoding="utf-8")
        implementation_prompt_path.write_text(
            build_implementation_prompt(
                project=project,
                task=task,
                plan_body=packet.body,
            ),
            encoding="utf-8",
        )

        db.record_packet(
            packet_id=packet.envelope.packet_id,
            task_id=task.id,
            stage=packet.envelope.stage.value,
            sha256=packet.sha256,
        )
        needs_confirmation = (
            packet.envelope.requires_human_approval_before_execution
            or packet.envelope.risk.requires_confirmation
            or packet.envelope.execution.model_role.value == "sol"
            or packet.envelope.execution.reasoning_effort.value == "xhigh"
        )
        db.update_task_plan(
            task_id=task.id,
            plan_path=plan_path,
            recommended_model=packet.envelope.execution.model_role.value,
            reasoning_effort=packet.envelope.execution.reasoning_effort.value,
            risk_level=packet.envelope.risk.level,
            requires_human_approval=needs_confirmation,
        )
    except (AiflowError, OSError) as exc:
        _fail(str(exc))

    warning = (
        "\n[bold yellow]Human approval required before execution.[/bold yellow]"
        if needs_confirmation
        else ""
    )
    console.print(
        Panel.fit(
            f"[bold green]Plan imported[/bold green]\n"
            f"Project: {project.name}\n"
            f"Task: {task.id}\n"
            f"Model: {packet.envelope.execution.model_role.value}\n"
            f"Reasoning: {packet.envelope.execution.reasoning_effort.value}\n"
            f"Risk: {packet.envelope.risk.level}\n"
            f"Plan: {plan_path}\n"
            f"Implementation prompt: {implementation_prompt_path}"
            f"{warning}\n\n"
            "Preview the eventual command with:\n"
            f"aiflow run {task.id} --dry-run",
            title="Ready for implementation",
        )
    )


@app.command()
def run(
    task_id: Annotated[
        str,
        typer.Argument(help="Task ID to preview or execute."),
    ],
    dry_run: Annotated[
        bool,
        typer.Option(
            "--dry-run/--execute",
            help="Preview by default.",
        ),
    ] = True,
    yes: Annotated[
        bool,
        typer.Option(
            "--yes",
            help="Skip the normal execution confirmation.",
        ),
    ] = False,
    approve_high_risk: Annotated[
        bool,
        typer.Option(
            "--approve-high-risk",
            help="Explicitly approve a Sol, xhigh, or sensitive execution recommendation.",
        ),
    ] = False,
) -> None:
    """Preview or execute the Codex implementation command for a task."""
    try:
        db = _db()
        task = db.get_task(task_id)
        if task is None:
            raise StateError(f"unknown task ID: {task_id}")
        if task.status != TaskStatus.READY_TO_RUN:
            raise StateError(f"task is not ready to run; current status is {task.status.value}")
        project = db.get_project(task.project_id)
        if project is None:
            raise StateError(f"project no longer exists: {task.project_id}")
        if not task.recommended_model or not task.reasoning_effort:
            raise StateError("task does not contain a model recommendation")

        validate_repository_state(
            project.path,
            expected_sha=task.base_sha,
            expected_branch=task.branch,
        )

        model_id = MODEL_BY_ROLE[task.recommended_model]
        prompt_path = task.task_dir / "implementation-prompt.md"
        report_path = task.task_dir / "implementation-report.md"
        if task.requires_human_approval and not approve_high_risk and not dry_run:
            raise StateError(
                "this plan requires explicit high-risk approval; "
                "inspect it and rerun with --execute --approve-high-risk"
            )

        spec = CodexRunSpec(
            repository_path=project.path,
            model_id=model_id,
            reasoning_effort=task.reasoning_effort,
            prompt_path=prompt_path,
            report_path=report_path,
        )
        command = build_codex_command(spec)
    except AiflowError as exc:
        _fail(str(exc))

    console.print(
        Panel(
            f"Project: {project.name}\n"
            f"Repository: {project.path}\n"
            f"Model: {model_id}\n"
            f"Reasoning: {task.reasoning_effort}\n"
            f"Risk: {task.risk_level or 'unknown'}\n"
            f"Explicit approval required: {task.requires_human_approval}\n\n"
            f"[bold]Command[/bold]\n{display_command(command)}",
            title="Codex execution preview",
        )
    )

    if dry_run:
        console.print("[yellow]Dry run only. No Codex usage was consumed.[/yellow]")
        return

    if not yes and not typer.confirm("Run this Codex implementation now?"):
        console.print("Cancelled.")
        return

    db.update_task_status(
        task_id=task.id,
        status=TaskStatus.RUNNING,
    )

    try:
        exit_code = execute_codex(spec)
    except AiflowError as exc:
        db.update_task_status(
            task_id=task.id,
            status=TaskStatus.FAILED,
        )
        _fail(str(exc))

    if exit_code != 0:
        db.update_task_status(
            task_id=task.id,
            status=TaskStatus.FAILED,
        )
        _fail(
            f"Codex exited with status {exit_code}",
            code=exit_code,
        )

    db.update_task_status(
        task_id=task.id,
        status=TaskStatus.IMPLEMENTED,
    )

    console.print(f"[bold green]Codex completed.[/bold green] Report: {report_path}")


@app.command()
def show(
    task_id: Annotated[
        str,
        typer.Argument(help="Task ID to display."),
    ],
) -> None:
    """Show one task and its artifact paths."""
    task = _db().get_task(task_id)
    if task is None:
        _fail(f"unknown task ID: {task_id}")

    project = _db().get_project(task.project_id)
    console.print(
        Panel.fit(
            f"Task: {task.id}\n"
            f"Project: {project.name if project else task.project_id}\n"
            f"Status: {task.status.value}\n"
            f"Title: {task.title}\n"
            f"Base SHA: {task.base_sha}\n"
            f"Branch: {task.branch}\n"
            f"Model: {task.recommended_model or '—'}\n"
            f"Reasoning: {task.reasoning_effort or '—'}\n"
            f"Risk: {task.risk_level or '—'}\n"
            f"Explicit approval required: {task.requires_human_approval}\n"
            f"Artifacts: {task.task_dir}",
            title="Aiflow task",
        )
    )


def main() -> None:
    app()


if __name__ == "__main__":
    main()
