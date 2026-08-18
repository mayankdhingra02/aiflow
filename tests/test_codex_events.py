import json
from pathlib import Path

from aiflow.codex_events import (
    summarize_codex_events,
    write_codex_event_summary,
)


def test_summarizes_codex_jsonl_events(
    tmp_path: Path,
) -> None:
    events_path = tmp_path / "events.jsonl"

    events_path.write_text(
        "\n".join(
            [
                ('{"type":"thread.started","thread_id":"abc"}'),
                '{"type":"turn.started"}',
                ('{"type":"item.completed","item":{"type":"command_execution"}}'),
                ('{"type":"item.completed","item":{"type":"file_change"}}'),
                (
                    '{"type":"turn.completed",'
                    '"usage":{'
                    '"input_tokens":100,'
                    '"cached_input_tokens":40,'
                    '"output_tokens":20,'
                    '"reasoning_output_tokens":5'
                    "}}"
                ),
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    summary = summarize_codex_events(events_path)

    assert summary.present is True
    assert summary.event_count == 5
    assert summary.invalid_line_count == 0

    assert summary.event_types["item.completed"] == 2

    assert summary.item_types["command_execution"] == 1

    assert summary.item_types["file_change"] == 1

    assert summary.usage["input_tokens"] == 100

    assert summary.usage["output_tokens"] == 20


def test_invalid_jsonl_lines_are_counted(
    tmp_path: Path,
) -> None:
    events_path = tmp_path / "events.jsonl"

    events_path.write_text(
        ('{"type":"turn.started"}\nthis-is-not-json\n'),
        encoding="utf-8",
    )

    summary = summarize_codex_events(events_path)

    assert summary.event_count == 1
    assert summary.invalid_line_count == 1


def test_writes_event_summary_file(
    tmp_path: Path,
) -> None:
    events_path = tmp_path / "events.jsonl"

    events_path.write_text(
        ('{"type":"turn.completed","usage":{"input_tokens":7}}\n'),
        encoding="utf-8",
    )

    summary_path = tmp_path / "summary.json"

    summary = write_codex_event_summary(
        events_path=events_path,
        summary_path=summary_path,
    )

    assert summary.event_count == 1
    assert summary_path.exists()

    payload = json.loads(
        summary_path.read_text(
            encoding="utf-8",
        )
    )
    assert payload["events_file"] == "events.jsonl"
    assert payload["version"] == 1
    assert payload["event_count"] == 1
    assert payload["usage"]["input_tokens"] == 7
