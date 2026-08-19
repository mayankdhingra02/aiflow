import subprocess
from pathlib import Path

from aiflow.review import (
    compute_worktree_fingerprint,
)


def _git(
    root: Path,
    *args: str,
) -> None:
    subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )


def _repository(
    tmp_path: Path,
) -> Path:
    root = tmp_path / "repo"
    root.mkdir()

    _git(
        root,
        "init",
        "-b",
        "main",
    )

    _git(
        root,
        "config",
        "user.name",
        "Test User",
    )

    _git(
        root,
        "config",
        "user.email",
        "test@example.com",
    )

    (root / "app.py").write_text(
        "value = 1\n",
        encoding="utf-8",
    )

    _git(
        root,
        "add",
        "app.py",
    )

    _git(
        root,
        "commit",
        "-m",
        "initial",
    )

    return root


def test_fingerprint_is_stable_for_same_worktree(
    tmp_path: Path,
) -> None:
    root = _repository(tmp_path)

    first = compute_worktree_fingerprint(root)

    second = compute_worktree_fingerprint(root)

    assert first == second
    assert len(first) == 64


def test_fingerprint_changes_for_tracked_edit(
    tmp_path: Path,
) -> None:
    root = _repository(tmp_path)

    before = compute_worktree_fingerprint(root)

    (root / "app.py").write_text(
        "value = 2\n",
        encoding="utf-8",
    )

    after = compute_worktree_fingerprint(root)

    assert after != before


def test_fingerprint_changes_for_untracked_file(
    tmp_path: Path,
) -> None:
    root = _repository(tmp_path)

    before = compute_worktree_fingerprint(root)

    (root / "new.py").write_text(
        "created = True\n",
        encoding="utf-8",
    )

    after = compute_worktree_fingerprint(root)

    assert after != before
