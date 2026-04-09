from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

from app.schemas.recipe import RecipePayload


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
