from __future__ import annotations

import base64

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.models import Recipe, RecipeMemory
from app.schemas.recipe_memory import RecipeMemoryCreateRequest, RecipeMemoryOut


router = APIRouter(prefix="/api/recipes", tags=["recipe-memories"])

# Cap upload size at ~5 MB of base64 (~3.7 MB raw). Keeps a single
# memory row from blowing the JSON request limit.
_MAX_PHOTO_BASE64_BYTES = 5 * 1024 * 1024


def _ensure_recipe(session: Session, recipe_id: str, user_id: str) -> Recipe:
    """Owner-scoped lookup. Raises 404 instead of leaking that the
    recipe exists for another user."""
    recipe = session.scalar(
        select(Recipe).where(Recipe.id == recipe_id, Recipe.user_id == user_id)
    )
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return recipe


def _photo_url(memory: RecipeMemory) -> str | None:
    if memory.image_bytes is None:
        return None
    ts = int(memory.created_at.timestamp())
    return f"/api/recipes/{memory.recipe_id}/memories/{memory.id}/photo?v={ts}"


def _to_payload(memory: RecipeMemory) -> RecipeMemoryOut:
    return RecipeMemoryOut(
        id=memory.id,
        body=memory.body,
        created_at=memory.created_at,
        photo_url=_photo_url(memory),
    )


@router.get("/{recipe_id}/memories", response_model=list[RecipeMemoryOut])
def list_memories(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[RecipeMemoryOut]:
    _ensure_recipe(session, recipe_id, current_user.id)
    # Explicit column-list select so the LargeBinary `image_bytes`
    # column never gets pulled into a list response. Bytes ride the
    # dedicated `…/photo` route instead.
    rows = session.execute(
        select(
            RecipeMemory.id,
            RecipeMemory.recipe_id,
            RecipeMemory.body,
            RecipeMemory.created_at,
            RecipeMemory.mime_type,
        )
        .where(RecipeMemory.recipe_id == recipe_id)
        .order_by(RecipeMemory.created_at.desc())
    ).all()
    out: list[RecipeMemoryOut] = []
    for row in rows:
        ts = int(row.created_at.timestamp())
        photo_url = (
            f"/api/recipes/{row.recipe_id}/memories/{row.id}/photo?v={ts}"
            if row.mime_type
            else None
        )
        out.append(
            RecipeMemoryOut(
                id=row.id,
                body=row.body,
                created_at=row.created_at,
                photo_url=photo_url,
            )
        )
    return out


@router.post("/{recipe_id}/memories", response_model=RecipeMemoryOut)
def create_memory(
    recipe_id: str,
    payload: RecipeMemoryCreateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> RecipeMemoryOut:
    _ensure_recipe(session, recipe_id, current_user.id)
    body = (payload.body or "").strip()
    if not body:
        raise HTTPException(status_code=400, detail="Memory body cannot be empty")

    image_bytes: bytes | None = None
    mime_type: str | None = None
    if payload.image_base64:
        if len(payload.image_base64) > _MAX_PHOTO_BASE64_BYTES:
            raise HTTPException(status_code=413, detail="Photo too large")
        try:
            image_bytes = base64.b64decode(payload.image_base64)
        except (ValueError, TypeError) as exc:
            raise HTTPException(status_code=400, detail=f"Invalid base64: {exc}") from exc
        mime_type = (payload.mime_type or "image/jpeg").strip() or "image/jpeg"

    memory = RecipeMemory(
        recipe_id=recipe_id,
        body=body,
        image_bytes=image_bytes,
        mime_type=mime_type,
    )
    session.add(memory)
    session.commit()
    session.refresh(memory)
    return _to_payload(memory)


@router.delete("/{recipe_id}/memories/{memory_id}", status_code=204)
def delete_memory(
    recipe_id: str,
    memory_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> None:
    _ensure_recipe(session, recipe_id, current_user.id)
    memory = session.scalar(
        select(RecipeMemory).where(
            RecipeMemory.id == memory_id, RecipeMemory.recipe_id == recipe_id
        )
    )
    if memory is None:
        raise HTTPException(status_code=404, detail="Memory not found")
    session.delete(memory)
    session.commit()


@router.get("/{recipe_id}/memories/{memory_id}/photo")
def fetch_memory_photo(
    recipe_id: str,
    memory_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    _ensure_recipe(session, recipe_id, current_user.id)
    memory = session.scalar(
        select(RecipeMemory).where(
            RecipeMemory.id == memory_id, RecipeMemory.recipe_id == recipe_id
        )
    )
    if memory is None or memory.image_bytes is None:
        raise HTTPException(status_code=404, detail="No photo for this memory")

    etag = f'"{int(memory.created_at.timestamp())}"'
    return Response(
        content=memory.image_bytes,
        media_type=memory.mime_type or "image/jpeg",
        headers={
            "ETag": etag,
            "Cache-Control": "public, max-age=31536000, immutable",
        },
    )
