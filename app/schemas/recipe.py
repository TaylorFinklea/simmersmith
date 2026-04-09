from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator


class RecipeIngredientPayload(BaseModel):
    ingredient_id: str | None = None
    ingredient_name: str
    normalized_name: str | None = None
    base_ingredient_id: str | None = None
    base_ingredient_name: str | None = None
    ingredient_variation_id: str | None = None
    ingredient_variation_name: str | None = None
    resolution_status: Literal["unresolved", "suggested", "resolved", "locked"] = "unresolved"
    quantity: float | None = None
    unit: str = ""
    prep: str = ""
    category: str = ""
    notes: str = ""


class RecipeStepPayload(BaseModel):
    step_id: str | None = None
    sort_order: int = 0
    instruction: str
    substeps: list["RecipeStepPayload"] = Field(default_factory=list)


class ManagedListItemOut(BaseModel):
    item_id: str
    kind: Literal["cuisine", "tag", "unit"]
    name: str
    normalized_name: str
    updated_at: datetime


class ManagedListItemCreateRequest(BaseModel):
    name: str


class NutritionSummaryOut(BaseModel):
    total_calories: float | None = None
    calories_per_serving: float | None = None
    coverage_status: Literal["complete", "partial", "unavailable"] = "unavailable"
    matched_ingredient_count: int = 0
    unmatched_ingredient_count: int = 0
    unmatched_ingredients: list[str] = Field(default_factory=list)
    last_calculated_at: datetime | None = None


class NutritionItemOut(BaseModel):
    item_id: str
    name: str
    normalized_name: str
    reference_amount: float
    reference_unit: str
    calories: float
    notes: str = ""


class IngredientNutritionMatchRequest(BaseModel):
    ingredient_name: str
    normalized_name: str | None = None
    nutrition_item_id: str


class IngredientNutritionMatchOut(BaseModel):
    match_id: str
    ingredient_name: str
    normalized_name: str
    nutrition_item: NutritionItemOut
    updated_at: datetime


class RecipeMetadataOut(BaseModel):
    updated_at: datetime | None = None
    cuisines: list[ManagedListItemOut] = Field(default_factory=list)
    tags: list[ManagedListItemOut] = Field(default_factory=list)
    units: list[ManagedListItemOut] = Field(default_factory=list)
    default_template_id: str | None = None
    templates: list["RecipeTemplateOut"] = Field(default_factory=list)


class RecipeTemplateOut(BaseModel):
    template_id: str
    slug: str
    name: str
    description: str = ""
    section_order: list[str] = Field(default_factory=list)
    share_source: bool = True
    share_memories: bool = True
    built_in: bool = False
    updated_at: datetime


class RecipePayload(BaseModel):
    recipe_id: str | None = None
    recipe_template_id: str | None = None
    base_recipe_id: str | None = None
    name: str
    meal_type: str = ""
    cuisine: str = ""
    servings: float | None = None
    prep_minutes: int | None = None
    cook_minutes: int | None = None
    tags: list[str] = Field(default_factory=list)
    instructions_summary: str = ""
    favorite: bool = False
    source: str = "ai"
    source_label: str = ""
    source_url: str = ""
    notes: str = ""
    memories: str = ""
    last_used: date | None = None
    ingredients: list[RecipeIngredientPayload] = Field(default_factory=list)
    steps: list[RecipeStepPayload] = Field(default_factory=list)
    nutrition_summary: NutritionSummaryOut | None = None


class RecipeOut(RecipePayload):
    recipe_id: str
    is_variant: bool = False
    override_fields: list[str] = Field(default_factory=list)
    variant_count: int = 0
    source_recipe_count: int = 0
    family_last_used: date | None = None
    days_since_last_used: int | None = None
    family_days_since_last_used: int | None = None
    archived: bool
    archived_at: datetime | None = None
    updated_at: datetime


class RecipeImportRequest(BaseModel):
    url: str

    @field_validator("url")
    @classmethod
    def validate_url_safe(cls, v: str) -> str:
        """Block non-HTTP schemes and private/internal IP ranges to prevent SSRF."""
        import ipaddress
        from urllib.parse import urlparse

        parsed = urlparse(v)
        if parsed.scheme not in ("http", "https"):
            raise ValueError(f"Only http and https URLs are allowed, got {parsed.scheme!r}")
        hostname = parsed.hostname or ""
        if not hostname:
            raise ValueError("URL must include a hostname")
        try:
            addr = ipaddress.ip_address(hostname)
            if addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_reserved:
                raise ValueError("URLs pointing to private or internal addresses are not allowed")
        except ValueError as exc:
            if "not allowed" in str(exc):
                raise
            # hostname is not an IP literal — allow DNS names through
        return v


class RecipeTextImportRequest(BaseModel):
    text: str
    title: str = ""
    source: str = "scan_import"
    source_label: str = ""
    source_url: str = ""


class RecipeVariationDraftRequest(BaseModel):
    goal: str


class RecipeSuggestionDraftRequest(BaseModel):
    goal: str


class RecipeCompanionDraftRequest(BaseModel):
    focus: Literal["sides_and_sauces"] = "sides_and_sauces"


class RecipeAIDraftOut(BaseModel):
    goal: str
    rationale: str = ""
    draft: RecipePayload


class RecipeAIDraftOptionOut(BaseModel):
    option_id: str
    label: str
    rationale: str = ""
    draft: RecipePayload


class RecipeAIOptionsOut(BaseModel):
    goal: str
    rationale: str = ""
    options: list[RecipeAIDraftOptionOut] = Field(default_factory=list)
