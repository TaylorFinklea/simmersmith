from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


PantryCadence = Literal["none", "weekly", "biweekly", "monthly"]


class StaplePayload(BaseModel):
    staple_name: str
    normalized_name: str
    notes: str = ""
    is_active: bool = True
    # M28 pantry extension. All optional so the pre-M28 PUT /api/profile
    # path keeps working unchanged for existing clients.
    typical_quantity: float | None = None
    typical_unit: str = ""
    recurring_quantity: float | None = None
    recurring_unit: str = ""
    recurring_cadence: PantryCadence = "none"
    category: str = ""


class PantryItemOut(BaseModel):
    """Full row shape for the M28 pantry CRUD endpoints. Carries the
    `pantry_item_id` so the iOS client can PATCH/DELETE by id without
    losing the recurring metadata.

    M29 build 56: `categories` is the new multi-value field. The
    legacy `category` single-string is the same data joined for
    older clients."""
    pantry_item_id: str
    staple_name: str
    normalized_name: str
    notes: str = ""
    is_active: bool = True
    typical_quantity: float | None = None
    typical_unit: str = ""
    recurring_quantity: float | None = None
    recurring_unit: str = ""
    recurring_cadence: PantryCadence = "none"
    category: str = ""
    categories: list[str] = Field(default_factory=list)
    last_applied_at: datetime | None = None
    frozen_at: datetime | None = None
    updated_at: datetime


class PantryItemAddRequest(BaseModel):
    staple_name: str = Field(min_length=1, max_length=255)
    normalized_name: str = ""
    notes: str = ""
    is_active: bool = True
    typical_quantity: float | None = None
    typical_unit: str = ""
    recurring_quantity: float | None = None
    recurring_unit: str = ""
    recurring_cadence: PantryCadence = "none"
    # `categories` wins when both are provided. Old clients can still
    # send `category` as a single string.
    category: str = ""
    categories: list[str] = Field(default_factory=list)
    frozen_at: datetime | None = None


class PantryItemPatchRequest(BaseModel):
    staple_name: str | None = Field(default=None, min_length=1, max_length=255)
    notes: str | None = None
    is_active: bool | None = None
    typical_quantity: float | None = None
    clear_typical_quantity: bool = False
    typical_unit: str | None = None
    recurring_quantity: float | None = None
    clear_recurring_quantity: bool = False
    recurring_unit: str | None = None
    recurring_cadence: PantryCadence | None = None
    category: str | None = None
    categories: list[str] | None = None
    frozen_at: datetime | None = None
    clear_frozen_at: bool = False


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


class UsageSummaryOut(BaseModel):
    action: str
    limit: int
    used: int
    remaining: int


class ImageUsageProvider(BaseModel):
    provider: str
    count: int
    cost_cents: int


class ImageUsageSummary(BaseModel):
    window_days: int
    total_count: int
    total_cost_cents: int
    by_provider: list[ImageUsageProvider]


class ProfileResponse(BaseModel):
    updated_at: datetime | None = None
    settings: dict[str, str]
    secret_flags: dict[str, bool] = Field(default_factory=dict)
    staples: list[StaplePayload]
    dietary_goal: DietaryGoalOut | None = None
    is_pro: bool = False
    is_trial: bool = False
    usage: list[UsageSummaryOut] = Field(default_factory=list)
    image_usage: ImageUsageSummary | None = None


class ProfileUpdateRequest(BaseModel):
    settings: dict[str, str] = Field(default_factory=dict)
    staples: list[StaplePayload] | None = None
