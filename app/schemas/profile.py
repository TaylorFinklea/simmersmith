from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class StaplePayload(BaseModel):
    staple_name: str
    normalized_name: str
    notes: str = ""
    is_active: bool = True


class ProfileResponse(BaseModel):
    updated_at: datetime | None = None
    settings: dict[str, str]
    secret_flags: dict[str, bool] = Field(default_factory=dict)
    staples: list[StaplePayload]


class ProfileUpdateRequest(BaseModel):
    settings: dict[str, str] = Field(default_factory=dict)
    staples: list[StaplePayload] | None = None
