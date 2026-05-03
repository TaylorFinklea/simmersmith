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


class GroceryItemPatchRequest(BaseModel):
    """Field-by-field PATCH. Pass a key with a value to set the
    override; pass with None to clear the override (revert to auto);
    omit the key to leave it untouched. `removed=true` soft-deletes the
    item via `is_user_removed`; `removed=false` undoes that.
    """
    model_config = ConfigDict(extra="forbid")

    name: Optional[str] = None
    quantity: Optional[float] = None
    unit: Optional[str] = None
    notes: Optional[str] = None
    category: Optional[str] = None
    removed: Optional[bool] = None


class GroceryListDeltaOut(BaseModel):
    """Delta response for the iOS Reminders sync engine. Includes
    tombstones (`is_user_removed=True`) so the device can detect
    removals it hasn't yet propagated to the local Reminders mirror.
    """
    week_id: str
    server_time: datetime
    items: list[GroceryItemOut]
