from __future__ import annotations

import base64
import logging

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings
from app.db import get_session
from app.models import Recipe, RecipeImage
from app.schemas import RecipeOut
from app.services.presenters import recipe_payload
from app.services.ai import profile_settings_map
from app.services.recipe_image_ai import (
    RecipeImageError,
    generate_recipe_image,
    is_image_gen_configured,
    persist_recipe_image,
)
from app.services.recipes import get_recipe


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/recipes", tags=["recipe-images"])


# Cap upload size at ~5 MB of base64 (~3.7 MB raw). Mirrors the
# memory-photo route's cap.
_MAX_PHOTO_BASE64_BYTES = 5 * 1024 * 1024


class RecipeImageUploadRequest(BaseModel):
    image_base64: str
    mime_type: str | None = None


def _ensure_recipe(session: Session, recipe_id: str, user_id: str) -> Recipe:
    recipe = session.scalar(
        select(Recipe).where(Recipe.id == recipe_id, Recipe.user_id == user_id)
    )
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return recipe


def _refreshed_payload(session: Session, user_id: str, recipe_id: str) -> dict[str, object]:
    refreshed = get_recipe(session, user_id, recipe_id)
    return recipe_payload(session, refreshed) if refreshed else {}


@router.get("/{recipe_id}/image")
def fetch_recipe_image(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    _ensure_recipe(session, recipe_id, current_user.id)

    image = session.scalar(select(RecipeImage).where(RecipeImage.recipe_id == recipe_id))
    if image is None:
        raise HTTPException(status_code=404, detail="No image for this recipe yet")

    # Cache for a year. The presenter busts the cache by appending
    # `?v=<generated_at_ts>` to the URL so the browser/iOS client
    # treats a regenerated image as a brand-new resource.
    etag = f'"{int(image.generated_at.timestamp())}"'
    return Response(
        content=image.image_bytes,
        media_type=image.mime_type or "image/png",
        headers={
            "ETag": etag,
            "Cache-Control": "public, max-age=31536000, immutable",
        },
    )


@router.post("/{recipe_id}/image/regenerate", response_model=RecipeOut)
def regenerate_recipe_image_route(
    recipe_id: str,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Re-roll the AI-generated header image. Uses the same auto-built
    prompt as the on-create flow — variety comes from the model's
    stochastic sampling. Provider is the user's `image_provider`
    profile setting (or the global default). 503 when the resolved
    provider's key isn't configured."""
    recipe = _ensure_recipe(session, recipe_id, current_user.id)
    user_settings = profile_settings_map(session, current_user.id)
    if not is_image_gen_configured(settings, user_settings=user_settings):
        raise HTTPException(status_code=503, detail="Image generation is not configured.")
    try:
        bytes_, mime, prompt = generate_recipe_image(
            recipe, settings=settings, user_settings=user_settings
        )
    except RecipeImageError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    persist_recipe_image(session, recipe.id, bytes_, mime, prompt)
    session.commit()
    return _refreshed_payload(session, current_user.id, recipe.id)


@router.put("/{recipe_id}/image", response_model=RecipeOut)
def upload_recipe_image_route(
    recipe_id: str,
    payload: RecipeImageUploadRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Replace the AI image with a user-uploaded photo. The bytes
    overwrite the existing `recipe_images` row and the prompt is
    set to a marker for log traceability."""
    recipe = _ensure_recipe(session, recipe_id, current_user.id)
    if not payload.image_base64:
        raise HTTPException(status_code=400, detail="Image bytes are required")
    if len(payload.image_base64) > _MAX_PHOTO_BASE64_BYTES:
        raise HTTPException(status_code=413, detail="Photo too large")
    try:
        image_bytes = base64.b64decode(payload.image_base64)
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=f"Invalid base64: {exc}") from exc
    mime = (payload.mime_type or "image/jpeg").strip() or "image/jpeg"
    persist_recipe_image(session, recipe.id, image_bytes, mime, prompt="user upload")
    session.commit()
    return _refreshed_payload(session, current_user.id, recipe.id)


@router.delete("/{recipe_id}/image", response_model=RecipeOut)
def delete_recipe_image_route(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Remove the recipe's image entirely. Idempotent — returns the
    recipe payload regardless of whether a row existed."""
    recipe = _ensure_recipe(session, recipe_id, current_user.id)
    image = session.scalar(select(RecipeImage).where(RecipeImage.recipe_id == recipe.id))
    if image is not None:
        session.delete(image)
        session.commit()
    return _refreshed_payload(session, current_user.id, recipe.id)
