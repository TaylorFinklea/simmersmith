from __future__ import annotations

from pydantic import BaseModel

from app.schemas.ai import AICapabilitiesOut


class HealthResponse(BaseModel):
    status: str
    ai_capabilities: AICapabilitiesOut | None = None
