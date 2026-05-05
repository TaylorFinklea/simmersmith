"""M26 Phase 3 — REST surface for per-household term aliases."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.schemas.aliases import HouseholdTermAliasOut, HouseholdTermAliasUpsertRequest
from app.services.aliases import delete_alias, list_aliases, upsert_alias


router = APIRouter(prefix="/api/household/aliases", tags=["aliases"])


def _payload(alias) -> dict[str, object]:
    return {
        "alias_id": alias.id,
        "term": alias.term,
        "expansion": alias.expansion,
        "notes": alias.notes,
        "updated_at": alias.updated_at,
    }


@router.get("", response_model=list[HouseholdTermAliasOut])
def list_household_aliases(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    return [_payload(a) for a in list_aliases(session, household_id=current_user.household_id)]


@router.post("", response_model=HouseholdTermAliasOut)
def upsert_household_alias(
    payload: HouseholdTermAliasUpsertRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    try:
        alias = upsert_alias(
            session,
            household_id=current_user.household_id,
            term=payload.term,
            expansion=payload.expansion,
            notes=payload.notes,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(alias)
    return _payload(alias)


@router.delete("/{term}", status_code=204)
def delete_household_alias(
    term: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> None:
    deleted = delete_alias(session, household_id=current_user.household_id, term=term)
    if not deleted:
        raise HTTPException(status_code=404, detail="Alias not found")
    session.commit()
