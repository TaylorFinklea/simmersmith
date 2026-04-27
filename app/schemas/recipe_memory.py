from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class RecipeMemoryOut(BaseModel):
    id: str
    body: str
    created_at: datetime
    photo_url: str | None = None


class RecipeMemoryCreateRequest(BaseModel):
    body: str
