from __future__ import annotations

from enum import StrEnum
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, field_validator

from aiflow.constants import ALLOWED_REASONING_EFFORTS, MODEL_BY_ROLE


class TaskStatus(StrEnum):
    WAITING_FOR_PLAN = "waiting_for_plan"
    PLAN_IMPORTED = "plan_imported"
    READY_TO_RUN = "ready_to_run"
    RUNNING = "running"
    IMPLEMENTED = "implemented"
    VALIDATING = "validating"
    VALIDATION_FAILED = "validation_failed"
    REVIEW_READY = "review_ready"
    WAITING_FOR_REVIEW = "waiting_for_review"
    REVIEW_IMPORTED = "review_imported"
    COMPLETED = "completed"
    FAILED = "failed"


class PacketStage(StrEnum):
    IMPLEMENTATION_PLAN = "implementation_plan"
    IMPLEMENTATION_REVIEW = "implementation_review"


class ModelRole(StrEnum):
    LUNA = "luna"
    TERRA = "terra"
    SOL = "sol"


class ReasoningEffort(StrEnum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    XHIGH = "xhigh"


class ExecutionRecommendation(BaseModel):
    model_config = ConfigDict(extra="forbid")

    model_role: ModelRole
    reasoning_effort: ReasoningEffort

    @property
    def model_id(self) -> str:
        return MODEL_BY_ROLE[self.model_role.value]


class RiskAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid")

    level: str = Field(pattern=r"^(low|medium|high|critical)$")
    touches_authentication: bool = False
    touches_authorization: bool = False
    touches_database: bool = False
    destructive_change: bool = False
    touches_secrets: bool = False
    touches_production_infrastructure: bool = False

    @property
    def requires_confirmation(self) -> bool:
        return any(
            (
                self.level in {"high", "critical"},
                self.touches_authentication,
                self.touches_authorization,
                self.destructive_change,
                self.touches_secrets,
                self.touches_production_infrastructure,
            )
        )


class PacketEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid")

    packet_version: int = Field(default=1, ge=1, le=1)
    packet_id: str = Field(min_length=8, max_length=128)
    project_id: str = Field(min_length=2, max_length=128)
    task_id: str = Field(min_length=8, max_length=160)
    nonce: str = Field(min_length=12, max_length=128)
    stage: PacketStage
    base_sha: str = Field(pattern=r"^[0-9a-fA-F]{7,64}$")
    review_fingerprint: str | None = Field(
        default=None,
        pattern=r"^[0-9a-fA-F]{64}$",
    )
    execution: ExecutionRecommendation
    risk: RiskAssessment
    requires_human_approval_before_execution: bool = False

    @field_validator("nonce")
    @classmethod
    def nonce_must_be_hex(cls, value: str) -> str:
        normalized = value.lower()
        if any(ch not in "0123456789abcdef" for ch in normalized):
            raise ValueError("nonce must contain only hexadecimal characters")
        return normalized


class ParsedPacket(BaseModel):
    model_config = ConfigDict(arbitrary_types_allowed=True)

    envelope: PacketEnvelope
    body: str = Field(min_length=1)
    raw_text: str
    sha256: str


class ProjectRecord(BaseModel):
    id: str
    name: str
    path: Path
    remote_url: str | None
    created_at: str
    updated_at: str


class TaskRecord(BaseModel):
    id: str
    project_id: str
    title: str
    request: str
    status: TaskStatus
    nonce: str
    base_sha: str
    branch: str
    task_dir: Path
    plan_path: Path | None = None
    recommended_model: str | None = None
    reasoning_effort: str | None = None
    risk_level: str | None = None
    requires_human_approval: bool = False
    created_at: str
    updated_at: str


class CodexRunSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    repository_path: Path
    model_id: str
    reasoning_effort: str
    prompt_path: Path
    report_path: Path
    sandbox: str = "workspace-write"

    @field_validator("reasoning_effort")
    @classmethod
    def validate_effort(cls, value: str) -> str:
        if value not in ALLOWED_REASONING_EFFORTS:
            raise ValueError(f"unsupported reasoning effort: {value}")
        return value
