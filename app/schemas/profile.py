from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class StaplePayload(BaseModel):
    staple_name: str
    normalized_name: str
    notes: str = ""
    is_active: bool = True


GoalType = Literal["lose", "maintain", "gain", "custom"]


class DietaryGoalPayload(BaseModel):
    """What the client sends to configure a goal."""
    goal_type: GoalType = "maintain"
    daily_calories: int = Field(ge=800, le=6000)
    protein_g: int = Field(ge=0, le=500)
    carbs_g: int = Field(ge=0, le=800)
    fat_g: int = Field(ge=0, le=400)
    fiber_g: int | None = Field(default=None, ge=0, le=200)
    notes: str = ""


class DietaryGoalOut(DietaryGoalPayload):
    updated_at: datetime


class ProfileResponse(BaseModel):
    updated_at: datetime | None = None
    settings: dict[str, str]
    secret_flags: dict[str, bool] = Field(default_factory=dict)
    staples: list[StaplePayload]
    dietary_goal: DietaryGoalOut | None = None


class ProfileUpdateRequest(BaseModel):
    settings: dict[str, str] = Field(default_factory=dict)
    staples: list[StaplePayload] | None = None
