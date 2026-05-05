"""M26 Phase 3 — household term-alias schemas."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class HouseholdTermAliasOut(BaseModel):
    alias_id: str
    term: str
    expansion: str
    notes: str
    updated_at: datetime


class HouseholdTermAliasUpsertRequest(BaseModel):
    term: str = Field(min_length=1, max_length=120)
    expansion: str = Field(min_length=1, max_length=255)
    notes: str = ""
