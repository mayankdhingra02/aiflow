from __future__ import annotations

import json
import sys
from pathlib import Path

from aiflow.validation import (
    ValidationCommand,
    discover_validation_commands,
    run_project_validations,
    run_validation_command,
    validations_passed,
)


def _write_package_json(
    root: Path,
    payload: dict[str, object],
) -> None:
    (root / "package.json").write_text(
        json.dumps(payload),
        encoding="utf-8",
    )


def test_discovers_known_node_validation_scripts(
    tmp_path: Path,
) -> None:
    _write_package_json(
        tmp_path,
        {
            "packageManager": "pnpm@10.0.0",
            "scripts": {
                "lint": "eslint .",
                "typecheck": "tsc --noEmit",
                "test": "vitest run",
                "build": "next build",
                "postinstall": ("do-not-run-this"),
                "deploy": ("do-not-run-this-either"),
            },
        },
    )

    commands = discover_validation_commands(tmp_path)

    assert [command.name for command in commands] == [
        "node:lint",
        "node:typecheck",
        "node:test",
        "node:build",
    ]

    assert [command.argv for command in commands] == [
        (
            "pnpm",
            "run",
            "lint",
        ),
        (
            "pnpm",
            "run",
            "typecheck",
        ),
        (
            "pnpm",
            "run",
            "test",
        ),
        (
            "pnpm",
            "run",
            "build",
        ),
    ]


def test_node_validation_ignores_arbitrary_scripts(
    tmp_path: Path,
) -> None:
    _write_package_json(
        tmp_path,
        {
            "scripts": {
                "deploy": ("rm -rf something"),
                "postinstall": ("curl example.com"),
            }
        },
    )

    commands = discover_validation_commands(tmp_path)

    assert commands == []


def test_discovers_python_validation(
    tmp_path: Path,
) -> None:
    (tmp_path / "src").mkdir()
    (tmp_path / "tests").mkdir()

    (tmp_path / "pyproject.toml").write_text(
        """
[project]
name = "demo"

[tool.ruff]
line-length = 100

[tool.pytest.ini_options]
testpaths = ["tests"]
""".strip(),
        encoding="utf-8",
    )

    commands = discover_validation_commands(tmp_path)

    names = [command.name for command in commands]

    assert names == [
        "python:ruff",
        "python:pytest",
        "python:compileall",
    ]


def test_discovers_go_validation(
    tmp_path: Path,
) -> None:
    (tmp_path / "go.mod").write_text(
        "module example.com/demo\n",
        encoding="utf-8",
    )

    commands = discover_validation_commands(tmp_path)

    assert commands == [
        ValidationCommand(
            name="go:test",
            argv=(
                "go",
                "test",
                "./...",
            ),
        )
    ]


def test_discovers_rust_validation(
    tmp_path: Path,
) -> None:
    (tmp_path / "Cargo.toml").write_text(
        ('[package]\nname = "demo"\nversion = "0.1.0"\n'),
        encoding="utf-8",
    )

    commands = discover_validation_commands(tmp_path)

    assert commands == [
        ValidationCommand(
            name="rust:test",
            argv=(
                "cargo",
                "test",
            ),
        )
    ]


def test_validation_runner_writes_log(
    tmp_path: Path,
) -> None:
    command = ValidationCommand(
        name="test:success",
        argv=(
            sys.executable,
            "-c",
            ("print('validation succeeded')"),
        ),
    )

    result = run_validation_command(
        root=tmp_path,
        command=command,
        logs_dir=tmp_path / "logs",
    )

    assert result.exit_code == 0
    assert result.passed is True
    assert result.output_path.exists()

    assert "validation succeeded" in result.output_path.read_text(encoding="utf-8")


def test_validation_runner_reports_missing_executable(
    tmp_path: Path,
) -> None:
    command = ValidationCommand(
        name="test:missing",
        argv=(("aiflow-command-that-does-not-exist"),),
    )

    result = run_validation_command(
        root=tmp_path,
        command=command,
        logs_dir=tmp_path / "logs",
    )

    assert result.exit_code == 127
    assert result.passed is False


def test_validations_passed_requires_evidence(
    tmp_path: Path,
) -> None:
    assert validations_passed([]) is False

    success = run_validation_command(
        root=tmp_path,
        command=ValidationCommand(
            name="success",
            argv=(
                sys.executable,
                "-c",
                "raise SystemExit(0)",
            ),
        ),
        logs_dir=tmp_path / "logs",
    )

    assert validations_passed([success]) is True

    failure = run_validation_command(
        root=tmp_path,
        command=ValidationCommand(
            name="failure",
            argv=(
                sys.executable,
                "-c",
                "raise SystemExit(3)",
            ),
        ),
        logs_dir=tmp_path / "logs",
    )

    assert (
        validations_passed(
            [
                success,
                failure,
            ]
        )
        is False
    )


def test_run_project_validations_writes_summary(
    tmp_path: Path,
) -> None:
    (tmp_path / "src").mkdir()
    (tmp_path / "tests").mkdir()

    (tmp_path / "pyproject.toml").write_text(
        """
[project]
name = "demo"

[tool.pytest.ini_options]
testpaths = ["tests"]
""".strip(),
        encoding="utf-8",
    )

    summary = run_project_validations(
        root=tmp_path,
        task_dir=tmp_path / "task",
    )

    assert summary.summary_path.exists()

    payload = json.loads(summary.summary_path.read_text(encoding="utf-8"))

    assert payload["version"] == 1
    assert payload["commands"]
    assert payload["results"]


def test_run_project_validations_without_commands_is_not_passed(
    tmp_path: Path,
) -> None:
    summary = run_project_validations(
        root=tmp_path,
        task_dir=tmp_path / "task",
    )

    assert summary.commands == ()
    assert summary.results == ()
    assert summary.passed is False
    assert summary.summary_path.exists()
