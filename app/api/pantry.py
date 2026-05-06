"""M28 — pantry REST surface.

The legacy `PUT /api/profile` flow still works for simple staple
edits (delete-then-recreate by name), but loses recurring metadata
and timestamps across saves. The pantry endpoints here PATCH by id,
so the recurring cadence + last_applied_at survive partial updates.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.schemas import (
    PantryItemAddRequest,
    PantryItemOut,
    PantryItemPatchRequest,
)
from app.services.pantry import (
    add_pantry_item,
    apply_pantry_recurrings,
    delete_pantry_item,
    get_pantry_item,
    list_pantry_items,
    update_pantry_item,
)
from app.services.weeks import get_week


router = APIRouter(prefix="/api/pantry", tags=["pantry"])


def _payload(item) -> dict[str, object]:
    from app.services.pantry import parse_categories

    return {
        "pantry_item_id": item.id,
        "staple_name": item.staple_name,
        "normalized_name": item.normalized_name,
        "notes": item.notes,
        "is_active": item.is_active,
        "typical_quantity": item.typical_quantity,
        "typical_unit": item.typical_unit,
        "recurring_quantity": item.recurring_quantity,
        "recurring_unit": item.recurring_unit,
        "recurring_cadence": item.recurring_cadence,
        "category": item.category,
        "categories": parse_categories(item.category),
        "last_applied_at": item.last_applied_at,
        "frozen_at": item.frozen_at,
        "updated_at": item.updated_at,
    }


@router.get("", response_model=list[PantryItemOut])
def list_pantry_route(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    return [_payload(i) for i in list_pantry_items(session, household_id=current_user.household_id)]


@router.post("", response_model=PantryItemOut)
def add_pantry_route(
    payload: PantryItemAddRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    try:
        item = add_pantry_item(
            session,
            user_id=current_user.id,
            household_id=current_user.household_id,
            name=payload.staple_name,
            notes=payload.notes,
            is_active=payload.is_active,
            typical_quantity=payload.typical_quantity,
            typical_unit=payload.typical_unit,
            recurring_quantity=payload.recurring_quantity,
            recurring_unit=payload.recurring_unit,
            recurring_cadence=payload.recurring_cadence,
            category=payload.category,
            categories=payload.categories or None,
            frozen_at=payload.frozen_at,
            normalized_name_override=payload.normalized_name,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(item)
    return _payload(item)


@router.patch("/{item_id}", response_model=PantryItemOut)
def patch_pantry_route(
    item_id: str,
    payload: PantryItemPatchRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    item = get_pantry_item(session, household_id=current_user.household_id, item_id=item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Pantry item not found")
    try:
        update_pantry_item(session, item=item, fields=payload.model_dump(exclude_unset=True))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(item)
    return _payload(item)


@router.delete("/{item_id}", status_code=204)
def delete_pantry_route(
    item_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> None:
    item = get_pantry_item(session, household_id=current_user.household_id, item_id=item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Pantry item not found")
    delete_pantry_item(session, item=item)
    session.commit()


@router.post("/apply/{week_id}", response_model=list[PantryItemOut])
def apply_pantry_route(
    week_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    """Fold this household's recurring pantry items into the given
    week's grocery list. Idempotent — re-running won't double-add.
    Returns the pantry items that landed (or were already present)."""
    week = get_week(session, current_user.household_id, week_id)
    if week is None:
        raise HTTPException(status_code=404, detail="Week not found")
    apply_pantry_recurrings(
        session,
        week=week,
        household_id=current_user.household_id,
    )
    session.commit()
    return [_payload(i) for i in list_pantry_items(session, household_id=current_user.household_id)]
