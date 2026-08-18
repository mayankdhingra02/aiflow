from __future__ import annotations

import dataclasses
import json
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_TIMEOUT_SECONDS = 600

NODE_VALIDATION_SCRIPTS = (
    "lint",
    "typecheck",
    "test",
    "build",
)


@dataclasses.dataclass(frozen=True)
class ValidationCommand:
    name: str
    argv: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class ValidationResult:
    name: str
    argv: tuple[str, ...]
    exit_code: int
    duration_seconds: float
    output_path: Path

    @property
    def passed(self) -> bool:
        return self.exit_code == 0


@dataclasses.dataclass(frozen=True)
class ValidationSummary:
    commands: tuple[ValidationCommand, ...]
    results: tuple[ValidationResult, ...]
    summary_path: Path

    @property
    def passed(self) -> bool:
        return bool(self.results) and all(result.passed for result in self.results)


def format_command(argv: tuple[str, ...]) -> str:
    return shlex.join(argv)


def _safe_log_name(name: str) -> str:
    normalized = re.sub(
        r"[^a-zA-Z0-9._-]+",
        "-",
        name.strip(),
    )
    normalized = normalized.strip("-")
    return normalized or "validation"


def _read_json(path: Path) -> dict[str, object] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
    ):
        return None

    if not isinstance(payload, dict):
        return None

    return payload


def _detect_node_package_manager(
    root: Path,
    package_json: dict[str, object],
) -> str:
    package_manager = package_json.get("packageManager")

    if isinstance(package_manager, str):
        candidate = package_manager.split("@", 1)[0].strip()

        if candidate in {
            "npm",
            "pnpm",
            "yarn",
            "bun",
        }:
            return candidate

    if (root / "pnpm-lock.yaml").exists():
        return "pnpm"

    if (root / "yarn.lock").exists():
        return "yarn"

    if (root / "bun.lock").exists() or (root / "bun.lockb").exists():
        return "bun"

    return "npm"


def _node_commands(
    root: Path,
) -> list[ValidationCommand]:
    package_json_path = root / "package.json"

    if not package_json_path.exists():
        return []

    package_json = _read_json(package_json_path)

    if package_json is None:
        return []

    scripts = package_json.get("scripts")

    if not isinstance(scripts, dict):
        return []

    manager = _detect_node_package_manager(
        root,
        package_json,
    )

    commands: list[ValidationCommand] = []

    for script_name in NODE_VALIDATION_SCRIPTS:
        script_value = scripts.get(script_name)

        if not isinstance(
            script_value,
            str,
        ):
            continue

        if not script_value.strip():
            continue

        commands.append(
            ValidationCommand(
                name=f"node:{script_name}",
                argv=(
                    manager,
                    "run",
                    script_name,
                ),
            )
        )

    return commands


def _project_python(root: Path) -> str:
    project_python = root / ".venv" / "bin" / "python"

    if project_python.exists():
        return str(project_python)

    return sys.executable


def _python_commands(
    root: Path,
) -> list[ValidationCommand]:
    pyproject = root / "pyproject.toml"
    setup_cfg = root / "setup.cfg"
    pytest_ini = root / "pytest.ini"

    has_python_project = any(
        path.exists()
        for path in (
            pyproject,
            setup_cfg,
            pytest_ini,
        )
    )

    if not has_python_project:
        return []

    python = _project_python(root)
    commands: list[ValidationCommand] = []

    pyproject_text = ""

    if pyproject.exists():
        try:
            pyproject_text = pyproject.read_text(encoding="utf-8")
        except (
            OSError,
            UnicodeDecodeError,
        ):
            pyproject_text = ""

    has_ruff = (
        "[tool.ruff" in pyproject_text
        or (root / "ruff.toml").exists()
        or (root / ".ruff.toml").exists()
    )

    if has_ruff:
        commands.append(
            ValidationCommand(
                name="python:ruff",
                argv=(
                    python,
                    "-m",
                    "ruff",
                    "check",
                    ".",
                ),
            )
        )

    has_pytest = (
        (root / "tests").is_dir() or "[tool.pytest" in pyproject_text or pytest_ini.exists()
    )

    if has_pytest:
        commands.append(
            ValidationCommand(
                name="python:pytest",
                argv=(
                    python,
                    "-m",
                    "pytest",
                ),
            )
        )

    if (root / "src").is_dir():
        commands.append(
            ValidationCommand(
                name="python:compileall",
                argv=(
                    python,
                    "-m",
                    "compileall",
                    "-q",
                    "src",
                ),
            )
        )

    return commands


def _go_commands(
    root: Path,
) -> list[ValidationCommand]:
    if not (root / "go.mod").exists():
        return []

    return [
        ValidationCommand(
            name="go:test",
            argv=(
                "go",
                "test",
                "./...",
            ),
        )
    ]


def _rust_commands(
    root: Path,
) -> list[ValidationCommand]:
    if not (root / "Cargo.toml").exists():
        return []

    return [
        ValidationCommand(
            name="rust:test",
            argv=(
                "cargo",
                "test",
            ),
        )
    ]


def _gradle_commands(
    root: Path,
) -> list[ValidationCommand]:
    gradle_files = (
        root / "build.gradle",
        root / "build.gradle.kts",
    )

    if not any(path.exists() for path in gradle_files):
        return []

    wrapper = root / "gradlew"
    argv = (str(wrapper), "test") if wrapper.exists() else ("gradle", "test")

    return [
        ValidationCommand(
            name="gradle:test",
            argv=argv,
        )
    ]


def _maven_commands(
    root: Path,
) -> list[ValidationCommand]:
    if not (root / "pom.xml").exists():
        return []

    wrapper = root / "mvnw"
    argv = (str(wrapper), "test") if wrapper.exists() else ("mvn", "test")

    return [
        ValidationCommand(
            name="maven:test",
            argv=argv,
        )
    ]


def discover_validation_commands(
    root: Path,
) -> list[ValidationCommand]:
    resolved_root = root.resolve()

    commands = [
        *_node_commands(resolved_root),
        *_python_commands(resolved_root),
        *_go_commands(resolved_root),
        *_rust_commands(resolved_root),
        *_gradle_commands(resolved_root),
        *_maven_commands(resolved_root),
    ]

    seen: set[
        tuple[
            str,
            tuple[str, ...],
        ]
    ] = set()

    unique_commands: list[ValidationCommand] = []

    for command in commands:
        key = (
            command.name,
            command.argv,
        )

        if key in seen:
            continue

        seen.add(key)
        unique_commands.append(command)

    return unique_commands


def run_validation_command(
    *,
    root: Path,
    command: ValidationCommand,
    logs_dir: Path,
    timeout_seconds: int = (DEFAULT_TIMEOUT_SECONDS),
) -> ValidationResult:
    resolved_root = root.resolve()

    logs_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    output_path = logs_dir / (f"{_safe_log_name(command.name)}.log")

    started = time.monotonic()

    try:
        result = subprocess.run(
            list(command.argv),
            cwd=resolved_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout_seconds,
        )

        output = result.stdout or ""
        exit_code = result.returncode

    except FileNotFoundError as exc:
        output = (
            "Validation executable was "
            "not found.\n"
            f"Command: "
            f"{format_command(command.argv)}\n"
            f"Error: {exc}\n"
        )
        exit_code = 127

    except PermissionError as exc:
        output = (
            "Validation executable could "
            "not be run.\n"
            f"Command: "
            f"{format_command(command.argv)}\n"
            f"Error: {exc}\n"
        )
        exit_code = 126

    except subprocess.TimeoutExpired as exc:
        captured = exc.stdout or ""

        if isinstance(captured, bytes):
            captured = captured.decode(
                "utf-8",
                errors="replace",
            )

        output = f"{captured}\nValidation timed out after {timeout_seconds} seconds.\n"
        exit_code = 124

    duration = time.monotonic() - started

    output_path.write_text(
        output,
        encoding="utf-8",
    )

    return ValidationResult(
        name=command.name,
        argv=command.argv,
        exit_code=exit_code,
        duration_seconds=duration,
        output_path=output_path,
    )


def run_validation_commands(
    *,
    root: Path,
    commands: list[ValidationCommand],
    logs_dir: Path,
    timeout_seconds: int = (DEFAULT_TIMEOUT_SECONDS),
) -> list[ValidationResult]:
    results: list[ValidationResult] = []

    for command in commands:
        result = run_validation_command(
            root=root,
            command=command,
            logs_dir=logs_dir,
            timeout_seconds=timeout_seconds,
        )
        results.append(result)

    return results


def validations_passed(
    results: list[ValidationResult],
) -> bool:
    return bool(results) and all(result.passed for result in results)


def run_project_validations(
    *,
    root: Path,
    task_dir: Path,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
) -> ValidationSummary:
    task_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    commands = discover_validation_commands(root)

    logs_dir = task_dir / "validation"

    results = run_validation_commands(
        root=root,
        commands=commands,
        logs_dir=logs_dir,
        timeout_seconds=timeout_seconds,
    )

    summary_path = task_dir / "validation-summary.json"

    passed = bool(results) and all(result.passed for result in results)

    payload = {
        "version": 1,
        "passed": passed,
        "commands": [
            {
                "name": command.name,
                "argv": list(command.argv),
            }
            for command in commands
        ],
        "results": [
            {
                "name": result.name,
                "argv": list(result.argv),
                "exit_code": (result.exit_code),
                "passed": result.passed,
                "duration_seconds": round(
                    result.duration_seconds,
                    6,
                ),
                "output_file": (result.output_path.name),
            }
            for result in results
        ],
    }

    summary_path.write_text(
        json.dumps(
            payload,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    return ValidationSummary(
        commands=tuple(commands),
        results=tuple(results),
        summary_path=summary_path,
    )
