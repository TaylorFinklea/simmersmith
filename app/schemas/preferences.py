from __future__ import annotations

from pydantic import BaseModel, Field


class PreferenceSignalPayload(BaseModel):
    preference_id: str | None = None
    signal_type: str
    name: str
    normalized_name: str | None = None
    score: int = Field(default=0, ge=-5, le=5)
    weight: int = Field(default=3, ge=1, le=5)
    rationale: str = ""
    source: str = "user"
    active: bool = True


class PreferenceSignalOut(PreferenceSignalPayload):
    preference_id: str


class PreferenceSummary(BaseModel):
    hard_avoids: list[str] = Field(default_factory=list)
    strong_likes: list[str] = Field(default_factory=list)
    brands: list[str] = Field(default_factory=list)
    rules: list[str] = Field(default_factory=list)


class PreferenceContextResponse(BaseModel):
    signals: list[PreferenceSignalOut] = Field(default_factory=list)
    summary: PreferenceSummary


class PreferenceBatchUpsertRequest(BaseModel):
    signals: list[PreferenceSignalPayload] = Field(default_factory=list)


class MealScoreRequest(BaseModel):
    recipe_name: str
    cuisine: str = ""
    meal_type: str = ""
    ingredient_names: list[str] = Field(default_factory=list)
    tags: list[str] = Field(default_factory=list)


class MealScoreMatch(BaseModel):
    preference_id: str
    signal_type: str
    name: str
    contribution: int
    rationale: str = ""


class MealScoreResponse(BaseModel):
    total_score: int
    blocked: bool
    blockers: list[str] = Field(default_factory=list)
    matches: list[MealScoreMatch] = Field(default_factory=list)
