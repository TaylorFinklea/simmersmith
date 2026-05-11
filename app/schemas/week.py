from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field

from app.schemas.recipe import RecipeIngredientPayload, RecipePayload


def _coerce_to_date(value: object) -> object:
    """Accept ISO datetime strings for date fields.

    iOS clients serialize Swift ``Date`` values as full ISO-8601 datetimes
    with a timezone offset (e.g. ``2026-04-13T05:00:00.000+00:00``). Pydantic
    v2 rejects those for plain ``date`` fields when the time component is
    non-zero. We pre-parse and truncate to the date portion so the API stays
    forgiving about what the client sends.
    """
    if isinstance(value, str) and "T" in value:
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return value
        return parsed.date()
    return value


DateLike = Annotated[date, BeforeValidator(_coerce_to_date)]


class WeekCreateRequest(BaseModel):
    week_start: DateLike
    notes: str = ""


class MealDraftPayload(BaseModel):
    meal_id: str | None = None
    day_name: str
    meal_date: DateLike
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
    # `model` is a label stored in AIRun.model and used as an actor_label for
    # change batches. It is not forwarded to external APIs. Constrain length
    # and character set to prevent audit-log abuse without restricting
    # legitimate agent identifiers (e.g. "claude-sonnet-4.6", "gpt-5.4", "codex").
    model: str = Field(default="skill-chat", max_length=100, pattern=r"^[a-zA-Z0-9._\-/:]+$")
    profile_updates: dict[str, str] = Field(default_factory=dict)
    recipes: list[RecipePayload] = Field(default_factory=list)
    meal_plan: list[MealDraftPayload] = Field(default_factory=list)
    week_notes: str = ""


class MealUpdatePayload(BaseModel):
    meal_id: str | None = None
    day_name: str
    meal_date: DateLike
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
    is_user_added: bool = False
    is_user_removed: bool = False
    quantity_override: float | None = None
    unit_override: str | None = None
    notes_override: str | None = None
    is_checked: bool = False
    checked_at: datetime | None = None
    checked_by_user_id: str | None = None
    event_quantity: float | None = None
    # Build 87: optional store annotation (Kroger / Aldi / free-typed).
    # Empty when unset.
    store_label: str = ""
    updated_at: datetime
    retailer_prices: list[RetailerPriceOut] = Field(default_factory=list)


class PlanShoppingItemOut(BaseModel):
    """Build 87: a single row in the "what you still need this week"
    projection. Aggregated from meal ingredients, with pantry staples
    and items already on the grocery list filtered out. Not persisted —
    derived on each GET so it stays current with meal edits.
    """
    ingredient_name: str
    normalized_name: str
    total_quantity: float | None = None
    unit: str = ""
    quantity_text: str = ""
    category: str = ""
    source_meals: str = ""
    notes: str = ""


class PlanShoppingOut(BaseModel):
    week_id: str
    items: list[PlanShoppingItemOut] = Field(default_factory=list)


class MacroBreakdownOut(BaseModel):
    calories: float = 0.0
    protein_g: float = 0.0
    carbs_g: float = 0.0
    fat_g: float = 0.0
    fiber_g: float = 0.0


class DailyNutritionOut(MacroBreakdownOut):
    meal_date: DateLike


class WeekMealSideAddRequest(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    recipe_id: str | None = None
    notes: str = ""
    sort_order: int = 0


class WeekMealSidePatchRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=255)
    recipe_id: str | None = None
    clear_recipe: bool = False
    notes: str | None = None
    sort_order: int | None = None

    model_config = ConfigDict(extra="forbid")


class WeekMealSideOut(BaseModel):
    side_id: str
    week_meal_id: str
    recipe_id: str | None
    recipe_name: str | None = None
    name: str
    notes: str
    sort_order: int
    updated_at: datetime


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
    sides: list[WeekMealSideOut] = Field(default_factory=list)
    macros: MacroBreakdownOut | None = None


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
    nutrition_totals: list[DailyNutritionOut] = Field(default_factory=list)
    weekly_totals: MacroBreakdownOut | None = None


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
    retailer: str
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
