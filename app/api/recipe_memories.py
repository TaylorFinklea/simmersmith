from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.models import Recipe, RecipeMemory
from app.schemas.recipe_memory import RecipeMemoryCreateRequest, RecipeMemoryOut


router = APIRouter(prefix="/api/recipes", tags=["recipe-memories"])


def _ensure_recipe(session: Session, recipe_id: str, user_id: str) -> Recipe:
    """Owner-scoped lookup. Raises 404 instead of leaking that the
    recipe exists for another user."""
    recipe = session.scalar(
        select(Recipe).where(Recipe.id == recipe_id, Recipe.user_id == user_id)
    )
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return recipe


def _to_payload(memory: RecipeMemory) -> RecipeMemoryOut:
    return RecipeMemoryOut(id=memory.id, body=memory.body, created_at=memory.created_at)


@router.get("/{recipe_id}/memories", response_model=list[RecipeMemoryOut])
def list_memories(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[RecipeMemoryOut]:
    _ensure_recipe(session, recipe_id, current_user.id)
    rows = session.scalars(
        select(RecipeMemory)
        .where(RecipeMemory.recipe_id == recipe_id)
        .order_by(RecipeMemory.created_at.desc())
    ).all()
    return [_to_payload(memory) for memory in rows]


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
    memory = RecipeMemory(recipe_id=recipe_id, body=body)
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
