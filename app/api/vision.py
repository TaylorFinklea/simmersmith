"""Vision-AI routes (M11).

Endpoints accept base64-encoded images via JSON to keep the iOS client on
its existing JSON code path. Image-size + MIME validation lives in the
service layer (`app/services/vision_ai.py`); the route layer translates
service exceptions into HTTP errors.
"""
from __future__ import annotations

import base64
import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings
from app.db import get_session
from app.schemas import (
    CuisineUseOut,
    IngredientIdentificationOut,
    VisionImageRequest,
)
from app.services.ai import profile_settings_map
from app.services.vision_ai import identify_ingredient

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/vision", tags=["vision"])


def _decode_base64(payload: str) -> bytes:
    try:
        return base64.b64decode(payload, validate=True)
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=f"Invalid base64 image: {exc}") from exc


@router.post("/identify-ingredient", response_model=IngredientIdentificationOut)
def identify_ingredient_route(
    request: VisionImageRequest,
    user: CurrentUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
    session: Session = Depends(get_session),
) -> IngredientIdentificationOut:
    image_bytes = _decode_base64(request.image_base64)
    user_settings = profile_settings_map(session, user.id)
    try:
        result = identify_ingredient(
            image_bytes=image_bytes,
            mime_type=request.mime_type,
            settings=settings,
            user_settings=user_settings,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        logger.warning("Ingredient identification failed: %s", exc)
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return IngredientIdentificationOut(
        name=result.name,
        confidence=result.confidence,
        common_names=list(result.common_names),
        cuisine_uses=[CuisineUseOut(country=u.country, dish=u.dish) for u in result.cuisine_uses],
        recipe_match_terms=list(result.recipe_match_terms),
        notes=result.notes,
    )
