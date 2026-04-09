from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.recipe import RecipeIngredientPayload, RecipePayload


class WeekCreateRequest(BaseModel):
    week_start: date
    notes: str = ""


class MealDraftPayload(BaseModel):
    meal_id: str | None = None
    day_name: str
    meal_date: date
    slot: str
    recipe_id: str | None = None
    recipe_name: str
    servings: float | None = None
    source: str = "ai"
    approved: bool = False
    notes: str = ""
    ingredients: list[RecipeIngredientPayload] = Field(default_factory=list)


class DraftFromAIRequest(BaseModel):
    prompt: str
    model: str = "skill-chat"
    profile_updates: dict[str, str] = Field(default_factory=dict)
    recipes: list[RecipePayload] = Field(default_factory=list)
    meal_plan: list[MealDraftPayload] = Field(default_factory=list)
    week_notes: str = ""


class MealUpdatePayload(BaseModel):
    meal_id: str | None = None
    day_name: str
    meal_date: date
    slot: str
    recipe_id: str | None = None
    recipe_name: str = ""
    servings: float | None = None
    scale_multiplier: float = Field(default=1.0, gt=0)
    notes: str = ""
    approved: bool = False


class WeekChangeEventOut(BaseModel):
    change_event_id: str
    entity_type: str
    entity_id: str
    field_name: str
    before_value: str
    after_value: str
    created_at: datetime


class WeekChangeBatchOut(BaseModel):
    change_batch_id: str
    actor_type: str
    actor_label: str
    summary: str
    created_at: datetime
    events: list[WeekChangeEventOut] = Field(default_factory=list)


class FeedbackEntryPayload(BaseModel):
    feedback_id: str | None = None
    meal_id: str | None = None
    grocery_item_id: str | None = None
    target_type: Literal["meal", "ingredient", "brand", "shopping_item", "store", "week"]
    target_name: str
    normalized_name: str | None = None
    retailer: str = ""
    sentiment: int = Field(default=0, ge=-2, le=2)
    reason_codes: list[str] = Field(default_factory=list)
    notes: str = ""
    source: str = "ui"
    active: bool = True


class FeedbackEntryOut(FeedbackEntryPayload):
    feedback_id: str
    created_at: datetime
    updated_at: datetime


class WeekFeedbackSummary(BaseModel):
    total_entries: int = 0
    meal_entries: int = 0
    ingredient_entries: int = 0
    brand_entries: int = 0
    shopping_entries: int = 0
    store_entries: int = 0
    week_entries: int = 0


class WeekFeedbackResponse(BaseModel):
    week_id: str
    summary: WeekFeedbackSummary
    entries: list[FeedbackEntryOut] = Field(default_factory=list)


class ExportItemOut(BaseModel):
    export_item_id: str
    sort_order: int
    list_name: str
    title: str
    notes: str
    metadata_json: str
    status: str


class ExportRunOut(BaseModel):
    export_id: str
    destination: str
    export_type: str
    status: str
    item_count: int
    payload_json: str
    error: str
    external_ref: str
    created_at: datetime
    completed_at: datetime | None
    updated_at: datetime
    items: list[ExportItemOut] = Field(default_factory=list)


class ExportCreateRequest(BaseModel):
    destination: Literal["apple_reminders"] = "apple_reminders"
    export_type: Literal["meal_plan", "shopping_split"]


class ExportCompleteRequest(BaseModel):
    status: Literal["completed", "failed"] = "completed"
    external_ref: str = ""
    error: str = ""


class RetailerPriceOut(BaseModel):
    retailer: str
    status: str
    store_name: str
    product_name: str
    package_size: str
    unit_price: float | None
    line_price: float | None
    product_url: str
    availability: str
    candidate_score: float | None
    review_note: str
    raw_query: str
    scraped_at: datetime | None

    model_config = ConfigDict(from_attributes=True)


class GroceryItemOut(BaseModel):
    grocery_item_id: str
    ingredient_name: str
    normalized_name: str
    base_ingredient_id: str | None = None
    base_ingredient_name: str | None = None
    ingredient_variation_id: str | None = None
    ingredient_variation_name: str | None = None
    resolution_status: Literal["unresolved", "suggested", "resolved", "locked"] = "unresolved"
    total_quantity: float | None
    unit: str
    quantity_text: str
    category: str
    source_meals: str
    notes: str
    review_flag: str
    updated_at: datetime
    retailer_prices: list[RetailerPriceOut] = Field(default_factory=list)


class WeekMealOut(BaseModel):
    meal_id: str
    day_name: str
    meal_date: date
    slot: str
    recipe_id: str | None
    recipe_name: str
    servings: float | None
    scale_multiplier: float = 1.0
    source: str
    approved: bool
    notes: str
    ai_generated: bool
    updated_at: datetime
    ingredients: list[RecipeIngredientPayload] = Field(default_factory=list)


class WeekOut(BaseModel):
    week_id: str
    week_start: date
    week_end: date
    status: str
    notes: str
    ready_for_ai_at: datetime | None
    approved_at: datetime | None
    priced_at: datetime | None
    updated_at: datetime
    staged_change_count: int = 0
    feedback_count: int = 0
    export_count: int = 0
    meals: list[WeekMealOut] = Field(default_factory=list)
    grocery_items: list[GroceryItemOut] = Field(default_factory=list)


class WeekSummaryOut(BaseModel):
    week_id: str
    week_start: date
    week_end: date
    status: str
    notes: str
    ready_for_ai_at: datetime | None
    approved_at: datetime | None
    priced_at: datetime | None
    updated_at: datetime
    meal_count: int
    grocery_item_count: int
    staged_change_count: int = 0
    feedback_count: int = 0
    export_count: int = 0


class PricingResponse(BaseModel):
    week_id: str
    week_start: date
    totals: dict[str, float]
    items: list[GroceryItemOut]


class PricingImportItem(BaseModel):
    grocery_item_id: str
    retailer: Literal["aldi", "walmart", "sams_club"]
    status: Literal["matched", "review", "unavailable"] = "matched"
    store_name: str = ""
    product_name: str = ""
    package_size: str = ""
    unit_price: float | None = None
    line_price: float | None = None
    product_url: str = ""
    availability: str = ""
    candidate_score: float | None = None
    review_note: str = ""
    raw_query: str = ""
    scraped_at: datetime | None = None


class PricingImportRequest(BaseModel):
    items: list[PricingImportItem] = Field(default_factory=list)
    replace_existing: bool = True
    source: str = "agent-playwright"
