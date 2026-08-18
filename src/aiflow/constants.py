from __future__ import annotations

from typing import Final

PACKET_START: Final = "AIFLOW_PACKET_V1"
PACKET_BODY_SEPARATOR: Final = "---AIFLOW_BODY---"
PACKET_END: Final = "AIFLOW_PACKET_END"

MODEL_BY_ROLE: Final[dict[str, str]] = {
    "luna": "gpt-5.6-luna",
    "terra": "gpt-5.6-terra",
    "sol": "gpt-5.6-sol",
}

ALLOWED_REASONING_EFFORTS: Final[set[str]] = {
    "low",
    "medium",
    "high",
    "xhigh",
}

APP_NAME: Final = "Aiflow"
