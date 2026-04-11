from __future__ import annotations

import httpx
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import get_settings
from app.db import get_session
from app.schemas import AIProviderModelsOut, HealthResponse
from app.services.ai import ai_capabilities_payload, profile_settings_map
from app.services.provider_models import list_provider_models


router = APIRouter(prefix="/api/ai", tags=["ai"])


@router.get("/health", response_model=HealthResponse)
async def ai_health_detail(session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> HealthResponse:
    """Authenticated health endpoint with full AI capability details."""
    settings = get_settings()
    return HealthResponse(
        status="ok",
        ai_capabilities=await ai_capabilities_payload(settings, profile_settings_map(session, current_user.id)),
    )


@router.get("/providers/{provider_name}/models", response_model=AIProviderModelsOut)
def get_provider_models(
    provider_name: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    settings = get_settings()
    user_settings = profile_settings_map(session, current_user.id)
    try:
        return list_provider_models(provider_name, settings=settings, user_settings=user_settings)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except httpx.HTTPStatusError as exc:
        detail = f"{provider_name.capitalize()} model discovery failed: {exc.response.status_code}"
        raise HTTPException(status_code=502, detail=detail) from exc
    except httpx.HTTPError as exc:
        detail = f"{provider_name.capitalize()} model discovery failed."
        raise HTTPException(status_code=502, detail=detail) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
