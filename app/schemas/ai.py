from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class AIProviderTargetOut(BaseModel):
    provider_kind: Literal["mcp", "direct"]
    mode: Literal["mcp", "direct"]
    source: str
    provider_name: str | None = None
    mcp_server_name: str | None = None


class AIProviderAvailabilityOut(BaseModel):
    provider_id: str
    label: str
    provider_kind: Literal["mcp", "direct"]
    available: bool
    source: str


class AICapabilitiesOut(BaseModel):
    supports_user_override: bool = True
    preferred_mode: Literal["auto", "mcp", "direct", "hybrid"] = "auto"
    user_override_provider: str | None = None
    user_override_configured: bool = False
    default_target: AIProviderTargetOut | None = None
    available_providers: list[AIProviderAvailabilityOut] = Field(default_factory=list)


class AIModelOptionOut(BaseModel):
    provider_id: Literal["openai", "anthropic"]
    model_id: str
    display_name: str


class AIProviderModelsOut(BaseModel):
    provider_id: Literal["openai", "anthropic"]
    selected_model_id: str | None = None
    models: list[AIModelOptionOut] = Field(default_factory=list)
    source: str = "unconfigured"
