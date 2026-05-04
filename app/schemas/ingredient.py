from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class BaseIngredientPayload(BaseModel):
    base_ingredient_id: str | None = None
    name: str
    normalized_name: str | None = None
    category: str = ""
    default_unit: str = ""
    notes: str = ""
    source_name: str = ""
    source_record_id: str = ""
    source_url: str = ""
    provisional: bool = False
    active: bool = True
    nutrition_reference_amount: float | None = None
    nutrition_reference_unit: str = ""
    calories: float | None = None


class BaseIngredientOut(BaseIngredientPayload):
    base_ingredient_id: str
    normalized_name: str
    archived_at: datetime | None = None
    merged_into_id: str | None = None
    variation_count: int = 0
    preference_count: int = 0
    recipe_usage_count: int = 0
    grocery_usage_count: int = 0
    product_like: bool = False
    updated_at: datetime


class IngredientVariationPayload(BaseModel):
    ingredient_variation_id: str | None = None
    name: str
    normalized_name: str | None = None
    brand: str = ""
    upc: str = ""
    package_size_amount: float | None = None
    package_size_unit: str = ""
    count_per_package: float | None = None
    product_url: str = ""
    retailer_hint: str = ""
    notes: str = ""
    source_name: str = ""
    source_record_id: str = ""
    source_url: str = ""
    active: bool = True
    nutrition_reference_amount: float | None = None
    nutrition_reference_unit: str = ""
    calories: float | None = None


class IngredientVariationOut(IngredientVariationPayload):
    ingredient_variation_id: str
    base_ingredient_id: str
    normalized_name: str
    archived_at: datetime | None = None
    merged_into_id: str | None = None
    updated_at: datetime


class IngredientUsageSummaryOut(BaseModel):
    linked_recipe_ids: list[str] = Field(default_factory=list)
    linked_recipe_names: list[str] = Field(default_factory=list)
    linked_grocery_item_ids: list[str] = Field(default_factory=list)
    linked_grocery_names: list[str] = Field(default_factory=list)


class BaseIngredientDetailOut(BaseModel):
    ingredient: BaseIngredientOut
    variations: list[IngredientVariationOut] = Field(default_factory=list)
    preference: "IngredientPreferenceOut | None" = None
    usage: IngredientUsageSummaryOut = Field(default_factory=IngredientUsageSummaryOut)


class IngredientMergeRequest(BaseModel):
    target_id: str


class IngredientResolveRequest(BaseModel):
    ingredient_name: str
    normalized_name: str | None = None
    quantity: float | None = None
    unit: str = ""
    prep: str = ""
    category: str = ""
    notes: str = ""


class IngredientResolveOut(BaseModel):
    ingredient_name: str
    normalized_name: str
    quantity: float | None = None
    unit: str = ""
    prep: str = ""
    category: str = ""
    notes: str = ""
    base_ingredient_id: str | None = None
    base_ingredient_name: str | None = None
    ingredient_variation_id: str | None = None
    ingredient_variation_name: str | None = None
    resolution_status: Literal["unresolved", "suggested", "resolved", "locked"] = "unresolved"


class IngredientPreferencePayload(BaseModel):
    preference_id: str | None = None
    base_ingredient_id: str
    preferred_variation_id: str | None = None
    preferred_brand: str = ""
    # "avoid" / "allergy" are read by the week planner's preference-aware
    # path (gather_planning_context merges them into hard_avoids) in
    # addition to the existing product-selection modes.
    choice_mode: Literal[
        "preferred",
        "cheapest",
        "best_reviewed",
        "rotate",
        "no_preference",
        "avoid",
        "allergy",
    ] = "preferred"
    active: bool = True
    notes: str = ""
    # M24: rank=1 is the user's primary pick; rank=2 is the secondary
    # used as a fallback by the M23 cart-automation skill when the
    # primary is out of stock. Higher ranks supported but the iOS UI
    # currently surfaces 1-3.
    rank: int = 1


class IngredientPreferenceOut(IngredientPreferencePayload):
    preference_id: str
    base_ingredient_name: str
    preferred_variation_name: str | None = None
    updated_at: datetime
