from __future__ import annotations

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse, urlsplit, urlunsplit

from aiflow.errors import GitError


@dataclass(frozen=True)
class GitProjectFacts:
    root: Path
    name: str
    project_id: str
    remote_url: str | None
    branch: str
    head_sha: str
    dirty: bool


def run_git(args: list[str], cwd: Path, *, required: bool = True) -> str:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        raise GitError("Git is not installed or could not be executed") from exc

    if result.returncode != 0:
        if not required:
            return ""
        detail = result.stderr.strip() or result.stdout.strip() or "unknown Git error"
        raise GitError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout.strip()


def repository_root(path: Path) -> Path:
    root = run_git(["rev-parse", "--show-toplevel"], path)
    return Path(root).resolve()


def sanitize_remote_url(remote_url: str | None) -> str | None:
    """Remove credentials, query parameters, and fragments from a Git remote URL."""
    if not remote_url:
        return None
    candidate = remote_url.strip()
    if "://" not in candidate:
        # SCP-style SSH remotes such as git@github.com:owner/repo.git do not
        # contain passwords and are safe to retain as repository identifiers.
        return candidate

    parsed = urlsplit(candidate)
    host = parsed.hostname or ""
    if parsed.port is not None:
        host = f"{host}:{parsed.port}"
    return urlunsplit((parsed.scheme, host, parsed.path, "", ""))


def normalize_remote_name(remote_url: str | None, fallback: str) -> str:
    if not remote_url:
        return fallback

    candidate = remote_url.strip().rstrip("/")
    if candidate.startswith("git@") and ":" in candidate:
        candidate = candidate.split(":", 1)[1]
    else:
        parsed = urlparse(candidate)
        if parsed.path:
            candidate = parsed.path

    name = Path(candidate).name
    if name.endswith(".git"):
        name = name[:-4]
    return name or fallback


def slugify(value: str) -> str:
    value = value.lower().strip()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-") or "project"


def inspect_repository(path: Path) -> GitProjectFacts:
    root = repository_root(path)
    raw_remote = run_git(["remote", "get-url", "origin"], root, required=False) or None
    remote = sanitize_remote_url(raw_remote)
    name = normalize_remote_name(remote, root.name)
    branch = run_git(["rev-parse", "--abbrev-ref", "HEAD"], root)
    head_sha = run_git(["rev-parse", "HEAD"], root)
    dirty = bool(run_git(["status", "--porcelain"], root, required=False))
    identity = remote or str(root)
    identity_hash = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:8]
    project_id = f"{slugify(name)}-{identity_hash}"
    return GitProjectFacts(
        root=root,
        name=name,
        project_id=project_id,
        remote_url=remote,
        branch=branch,
        head_sha=head_sha,
        dirty=dirty,
    )


def _read_text(path: Path, *, limit: int) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    if len(text) > limit:
        return text[:limit] + "\n… [truncated by Aiflow]"
    return text


def _package_summary(root: Path) -> str:
    package_json = root / "package.json"
    if package_json.exists():
        try:
            data = json.loads(package_json.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return "package.json exists but could not be parsed."
        payload = {
            "name": data.get("name"),
            "packageManager": data.get("packageManager"),
            "scripts": data.get("scripts", {}),
            "dependencies": sorted((data.get("dependencies") or {}).keys()),
            "devDependencies": sorted((data.get("devDependencies") or {}).keys()),
        }
        return json.dumps(payload, indent=2)

    pyproject = root / "pyproject.toml"
    if pyproject.exists():
        return _read_text(pyproject, limit=12_000)

    for manifest in ("go.mod", "Cargo.toml", "pom.xml", "build.gradle", "build.gradle.kts"):
        path = root / manifest
        if path.exists():
            return _read_text(path, limit=12_000)

    return "No supported package manifest was detected."


def tracked_file_inventory(root: Path, *, limit: int = 400) -> tuple[list[str], bool]:
    output = run_git(["ls-files"], root, required=False)
    files = [line for line in output.splitlines() if line.strip()]
    truncated = len(files) > limit
    return files[:limit], truncated


def repository_context(root: Path) -> str:
    agents = _read_text(root / "AGENTS.md", limit=16_000) or "No root AGENTS.md was found."
    readme = ""
    for name in ("README.md", "README.rst", "README.txt"):
        candidate = root / name
        if candidate.exists():
            readme = _read_text(candidate, limit=10_000)
            break
    if not readme:
        readme = "No README was found."

    files, truncated = tracked_file_inventory(root)
    suffix = "\n… [file inventory truncated]" if truncated else ""

    return (
        "## Repository instructions\n"
        f"{agents}\n\n"
        "## Package/build manifest summary\n"
        f"{_package_summary(root)}\n\n"
        "## README excerpt\n"
        f"{readme}\n\n"
        "## Tracked file inventory\n"
        + "\n".join(f"- {path}" for path in files)
        + suffix
    )
