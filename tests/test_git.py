from aiflow.git import sanitize_remote_url


def test_sanitize_remote_url_removes_https_credentials_and_query() -> None:
    value = "https://secret-token@github.com/example/repo.git?token=another-secret#fragment"
    assert sanitize_remote_url(value) == "https://github.com/example/repo.git"


def test_sanitize_remote_url_preserves_scp_style_ssh() -> None:
    value = "git@github.com:example/repo.git"
    assert sanitize_remote_url(value) == value
