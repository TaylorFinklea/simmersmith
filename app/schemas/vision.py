from __future__ import annotations

from pydantic import BaseModel, Field


class VisionImageRequest(BaseModel):
    """Common request shape for vision endpoints. The iOS client encodes the
    image as base64 in JSON to avoid introducing a multipart-upload code path
    for a single feature."""

    image_base64: str
    mime_type: str = "image/jpeg"


class CuisineUseOut(BaseModel):
    country: str
    dish: str


class IngredientIdentificationOut(BaseModel):
    name: str
    confidence: str
    common_names: list[str] = Field(default_factory=list)
    cuisine_uses: list[CuisineUseOut] = Field(default_factory=list)
    recipe_match_terms: list[str] = Field(default_factory=list)
    notes: str = ""


class CookCheckRequest(VisionImageRequest):
    step_number: int = 0


class CookCheckOut(BaseModel):
    verdict: str
    tip: str
    suggested_minutes_remaining: int = 0
