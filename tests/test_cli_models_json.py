import json

from typer.testing import CliRunner

from aiflow.cli import app
from aiflow.constants import MODEL_BY_ROLE
from aiflow.models import (
    ModelRole,
    ReasoningEffort,
)

runner = CliRunner()


def test_models_json_matches_backend_constants() -> None:
    """The macOS widget reads model IDs from here, so they stay defined once in Python."""
    result = runner.invoke(app, ["models", "--json"])

    assert result.exit_code == 0

    payload = json.loads(result.stdout)

    assert payload["models"] == [
        {"role": role.value, "model_id": MODEL_BY_ROLE[role.value]} for role in ModelRole
    ]

    assert payload["reasoning_efforts"] == [effort.value for effort in ReasoningEffort]

    assert payload["default_sandbox"] == "workspace-write"


def test_models_without_json_prints_human_readable_table() -> None:
    result = runner.invoke(app, ["models"])

    assert result.exit_code == 0

    assert "terra" in result.stdout
