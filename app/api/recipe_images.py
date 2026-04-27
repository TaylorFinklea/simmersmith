from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.models import Recipe, RecipeImage


router = APIRouter(prefix="/api/recipes", tags=["recipe-images"])


@router.get("/{recipe_id}/image")
def fetch_recipe_image(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    # Verify recipe ownership before serving any image bytes — keeps
    # cross-user lookups out, mirrors the pattern in load_week_or_404.
    recipe = session.scalar(
        select(Recipe).where(Recipe.id == recipe_id, Recipe.user_id == current_user.id)
    )
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")

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
