"""M22 grocery list mutability schemas.

These models back the new `/api/weeks/{id}/grocery/...` routes that
let users add custom items, edit quantities/units/notes, soft-remove
items, and toggle household-shared check state. The PATCH model uses
Pydantic's `model_fields_set` so callers can distinguish "field
absent → leave alone" from "field present but null → clear override".
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.week import GroceryItemOut


class GroceryItemAddRequest(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    quantity: float | None = None
    unit: str = ""
    notes: str = ""
    category: str = ""
    # Build 87: optional per-item store annotation (Kroger / Aldi /
    # free-typed). Empty = no preference.
    store_label: str = ""


class GroceryItemQuickAddRequest(BaseModel):
    """Build 87: one-shot add from the plan-shopping sheet. Carries
    the aggregated row plus an optional store. Differs from
    ``GroceryItemAddRequest`` only in carrying the resolved category
    + quantity_text + normalized_name straight from the projection so
    iOS doesn't re-derive them.
    """
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=255)
    normalized_name: str = ""
    quantity: float | None = None
    quantity_text: str = ""
    unit: str = ""
    category: str = ""
    notes: str = ""
    store_label: str = ""


class GroceryItemPatchRequest(BaseModel):
    """Field-by-field PATCH. Pass a key with a value to set the
    override; pass with None to clear the override (revert to auto);
    omit the key to leave it untouched. `removed=true` soft-deletes the
    item via `is_user_removed`; `removed=false` undoes that.

    `base_ingredient_id` and `ingredient_variation_id` let the iOS
    review-queue link an unresolved row (e.g. a free-typed "almond
    flour") to a catalog entry. When `base_ingredient_id` is set the
    server flips `resolution_status` to "locked" so smart-merge regen
    treats the link as user-curated.
    """
    model_config = ConfigDict(extra="forbid")

    name: Optional[str] = None
    quantity: Optional[float] = None
    unit: Optional[str] = None
    notes: Optional[str] = None
    category: Optional[str] = None
    removed: Optional[bool] = None
    base_ingredient_id: Optional[str] = None
    ingredient_variation_id: Optional[str] = None
    # Build 87: PATCH the store annotation. Empty string clears it.
    store_label: Optional[str] = None


class GroceryListDeltaOut(BaseModel):
    """Delta response for the iOS Reminders sync engine. Includes
    tombstones (`is_user_removed=True`) so the device can detect
    removals it hasn't yet propagated to the local Reminders mirror.
    """
    week_id: str
    server_time: datetime
    items: list[GroceryItemOut]
