"""Discovery routes (M12) — features that surface ideas to the user
beyond what's already in their library. Currently exposes the in-season
produce snapshot; AI recipe web search lands here in Phase 4.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings
from app.db import get_session
from app.schemas import RecipePayload
from app.services.ai import profile_settings_map
from app.services.seasonal_ai import InSeasonItem, seasonal_produce

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["discovery"])


class RecipeWebSearchRequest(BaseModel):
    query: str = Field(min_length=2, max_length=400)


@router.post("/recipes/ai/web-search", response_model=RecipePayload)
def recipe_web_search_route(
    payload: RecipeWebSearchRequest,
    user: CurrentUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    """Find a real recipe online via OpenAI Responses API + web_search tool.

    Returns a `RecipePayload` for the iOS client to open in the editor.
    Nothing is persisted server-side — the user has to hit Save in the
    editor, mirroring the existing URL/text/PDF import flow.
    """
    from app.services.recipe_search_ai import search_recipe

    user_settings = profile_settings_map(session, user.id)
    try:
        return search_recipe(
            query=payload.query,
            settings=settings,
            user_settings=user_settings,
        ).model_dump()
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        logger.warning("Recipe web search failed: %s", exc)
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/seasonal/produce", response_model=list[InSeasonItem])
def seasonal_produce_route(
    user: CurrentUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
    session: Session = Depends(get_session),
) -> list[dict[str, object]]:
    """Return 5–8 in-season produce items for the user's region.

    The user's region comes from the `user_region` ProfileSetting, which
    they fill in via Settings on iOS. Empty/missing region → falls back
    to "United States".
    """
    user_settings = profile_settings_map(session, user.id)
    region = user_settings.get("user_region", "")
    try:
        items = seasonal_produce(
            region=region,
            settings=settings,
            user_settings=user_settings,
        )
    except RuntimeError as exc:
        logger.info("Seasonal produce lookup failed: %s", exc)
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return [item.model_dump() for item in items]
