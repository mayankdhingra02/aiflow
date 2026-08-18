from pathlib import Path

import pytest

from aiflow.errors import GitError
from aiflow.git import (
    GitProjectFacts,
    sanitize_remote_url,
    validate_repository_state,
)


def test_sanitize_remote_url_removes_https_credentials_and_query() -> None:
    value = "https://secret-token@github.com/example/repo.git?token=another-secret#fragment"
    assert sanitize_remote_url(value) == "https://github.com/example/repo.git"


def test_sanitize_remote_url_preserves_scp_style_ssh() -> None:
    value = "git@github.com:example/repo.git"
    assert sanitize_remote_url(value) == value


def test_validate_repository_state_rejects_changed_head(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    facts = GitProjectFacts(
        root=tmp_path,
        name="demo",
        project_id="demo",
        remote_url=None,
        branch="main",
        head_sha="b" * 40,
        dirty=False,
    )

    monkeypatch.setattr(
        "aiflow.git.inspect_repository",
        lambda _path: facts,
    )

    with pytest.raises(GitError, match="HEAD mismatch"):
        validate_repository_state(
            tmp_path,
            expected_sha="a" * 40,
            expected_branch="main",
        )
