from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CodexEventSummary:
    events_path: Path
    present: bool
    event_count: int
    invalid_line_count: int
    error_count: int
    event_types: dict[str, int]
    item_types: dict[str, int]
    usage: dict[str, int]

    def to_dict(
        self,
    ) -> dict[str, object]:
        return {
            "version": 1,
            "events_file": self.events_path.name,
            "present": self.present,
            "event_count": self.event_count,
            "invalid_line_count": (self.invalid_line_count),
            "error_count": self.error_count,
            "event_types": self.event_types,
            "item_types": self.item_types,
            "usage": self.usage,
        }


def summarize_codex_events(
    events_path: Path,
) -> CodexEventSummary:
    if not events_path.exists():
        return CodexEventSummary(
            events_path=events_path,
            present=False,
            event_count=0,
            invalid_line_count=0,
            error_count=0,
            event_types={},
            item_types={},
            usage={},
        )

    event_types: Counter[str] = Counter()
    item_types: Counter[str] = Counter()
    usage_totals: Counter[str] = Counter()

    event_count = 0
    invalid_line_count = 0
    error_count = 0

    try:
        lines = events_path.read_text(
            encoding="utf-8",
        ).splitlines()
    except (
        OSError,
        UnicodeDecodeError,
    ):
        return CodexEventSummary(
            events_path=events_path,
            present=True,
            event_count=0,
            invalid_line_count=1,
            error_count=1,
            event_types={},
            item_types={},
            usage={},
        )

    for line in lines:
        stripped = line.strip()

        if not stripped:
            continue

        try:
            event = json.loads(stripped)
        except json.JSONDecodeError:
            invalid_line_count += 1
            continue

        if not isinstance(event, dict):
            invalid_line_count += 1
            continue

        event_count += 1

        raw_event_type = event.get(
            "type",
            "unknown",
        )

        event_type = (
            raw_event_type
            if isinstance(
                raw_event_type,
                str,
            )
            else "unknown"
        )

        event_types[event_type] += 1

        if event_type in {
            "error",
            "turn.failed",
        }:
            error_count += 1

        item = event.get("item")

        if isinstance(item, dict):
            raw_item_type = item.get(
                "type",
                "unknown",
            )

            item_type = (
                raw_item_type
                if isinstance(
                    raw_item_type,
                    str,
                )
                else "unknown"
            )

            item_types[item_type] += 1

        usage = event.get("usage")

        if isinstance(usage, dict):
            for key, value in usage.items():
                if isinstance(key, str) and isinstance(value, int) and not isinstance(value, bool):
                    usage_totals[key] += value

    return CodexEventSummary(
        events_path=events_path,
        present=True,
        event_count=event_count,
        invalid_line_count=invalid_line_count,
        error_count=error_count,
        event_types=dict(sorted(event_types.items())),
        item_types=dict(sorted(item_types.items())),
        usage=dict(sorted(usage_totals.items())),
    )


def write_codex_event_summary(
    *,
    events_path: Path,
    summary_path: Path,
) -> CodexEventSummary:
    summary = summarize_codex_events(events_path)

    summary_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    summary_path.write_text(
        json.dumps(
            summary.to_dict(),
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    return summary
