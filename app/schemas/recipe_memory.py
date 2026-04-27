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
    image_base64: str | None = None
    mime_type: str | None = None
