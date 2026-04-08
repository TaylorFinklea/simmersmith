from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


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
    preference: IngredientPreferenceOut | None = None
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
    choice_mode: Literal["preferred", "cheapest", "best_reviewed", "rotate", "no_preference"] = "preferred"
    active: bool = True
    notes: str = ""


class IngredientPreferenceOut(IngredientPreferencePayload):
    preference_id: str
    base_ingredient_name: str
    preferred_variation_name: str | None = None
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


class AssistantThreadCreateRequest(BaseModel):
    title: str = ""


class AssistantRespondRequest(BaseModel):
    text: str = ""
    attached_recipe_id: str | None = None
    attached_recipe_draft: RecipePayload | None = None
    intent: Literal["general", "recipe_creation", "recipe_refinement", "cooking_help"] = "general"


class AssistantMessageOut(BaseModel):
    message_id: str
    thread_id: str
    role: Literal["user", "assistant", "system"]
    status: Literal["queued", "streaming", "completed", "failed"]
    content_markdown: str = ""
    recipe_draft: RecipePayload | None = None
    attached_recipe_id: str | None = None
    created_at: datetime
    completed_at: datetime | None = None
    error: str = ""


class AssistantThreadSummaryOut(BaseModel):
    thread_id: str
    title: str
    preview: str = ""
    created_at: datetime
    updated_at: datetime


class AssistantThreadOut(AssistantThreadSummaryOut):
    messages: list[AssistantMessageOut] = Field(default_factory=list)


class AssistantStreamEventOut(BaseModel):
    event: str
    payload: dict[str, object] = Field(default_factory=dict)


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


class HealthResponse(BaseModel):
    status: str
    ai_capabilities: AICapabilitiesOut | None = None


RecipeMetadataOut.model_rebuild()
RecipeStepPayload.model_rebuild()
