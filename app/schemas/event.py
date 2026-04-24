from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field


class GuestPayload(BaseModel):
    guest_id: str | None = None
    name: str
    relationship_label: str = ""
    dietary_notes: str = ""
    allergies: str = ""
    age_group: str = "adult"
    active: bool = True


class GuestOut(GuestPayload):
    guest_id: str
    created_at: datetime
    updated_at: datetime


class EventAttendeePayload(BaseModel):
    guest_id: str
    plus_ones: int = 0


class EventAttendeeOut(BaseModel):
    guest_id: str
    plus_ones: int
    guest: GuestOut


class EventMealIngredientPayload(BaseModel):
    ingredient_id: str | None = None
    ingredient_name: str
    normalized_name: str | None = None
    base_ingredient_id: str | None = None
    ingredient_variation_id: str | None = None
    quantity: float | None = None
    unit: str = ""
    prep: str = ""
    category: str = ""
    notes: str = ""


class EventMealPayload(BaseModel):
    meal_id: str | None = None
    role: Literal["main", "side", "starter", "dessert", "beverage", "other"] = "main"
    recipe_id: str | None = None
    recipe_name: str
    servings: float | None = None
    scale_multiplier: float = 1.0
    notes: str = ""
    sort_order: int = 0
    approved: bool = False
    constraint_coverage: list[str] = Field(default_factory=list)
    ingredients: list[EventMealIngredientPayload] = Field(default_factory=list)


class EventMealOut(EventMealPayload):
    meal_id: str
    ai_generated: bool
    created_at: datetime
    updated_at: datetime


class EventGroceryItemOut(BaseModel):
    grocery_item_id: str
    ingredient_name: str
    normalized_name: str
    base_ingredient_id: str | None
    ingredient_variation_id: str | None
    total_quantity: float | None
    unit: str
    quantity_text: str
    category: str
    source_meals: list[str] = Field(default_factory=list)
    notes: str = ""
    review_flag: str = ""
    merged_into_week_id: str | None = None
    merged_into_grocery_item_id: str | None = None


class EventCreateRequest(BaseModel):
    name: str
    event_date: date | None = None
    occasion: str = "other"
    attendee_count: int = 0
    notes: str = ""
    attendees: list[EventAttendeePayload] = Field(default_factory=list)


class EventUpdateRequest(BaseModel):
    name: str | None = None
    event_date: date | None = None
    occasion: str | None = None
    attendee_count: int | None = None
    notes: str | None = None
    status: str | None = None
    attendees: list[EventAttendeePayload] | None = None


class EventSummaryOut(BaseModel):
    event_id: str
    name: str
    event_date: date | None
    occasion: str
    attendee_count: int
    status: str
    linked_week_id: str | None
    meal_count: int
    created_at: datetime
    updated_at: datetime


class EventOut(EventSummaryOut):
    notes: str
    attendees: list[EventAttendeeOut]
    meals: list[EventMealOut]
    grocery_items: list[EventGroceryItemOut]


class EventMenuGenerateRequest(BaseModel):
    prompt: str = ""
    roles: list[str] = Field(
        default_factory=lambda: ["starter", "main", "side", "side", "dessert"]
    )


class EventMenuGenerateResponse(BaseModel):
    event: "EventOut"
    coverage_summary: str = ""


class EventGroceryMergeRequest(BaseModel):
    week_id: str
