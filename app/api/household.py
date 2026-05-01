"""Household sharing API (M21).

Endpoints:
- GET /api/household → current household + members + active invitations
- PUT /api/household → rename (owner only)
- POST /api/household/invitations → mint a code (owner only)
- DELETE /api/household/invitations/{code} → revoke (owner only)
- POST /api/household/join → claim an invitation; auto-merges joiner's
  solo content into the target household.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.models import Household, HouseholdInvitation, HouseholdMember
from app.schemas import (
    HouseholdInvitationOut,
    HouseholdMemberOut,
    HouseholdOut,
    HouseholdRenameRequest,
    InvitationCreatedOut,
    JoinHouseholdRequest,
)
from app.services.households import (
    InvitationError,
    InvitationExpiredError,
    InvitationNotFoundError,
    InvitationOwnHouseholdError,
    claim_invitation,
    create_invitation,
    list_active_invitations,
    list_members,
    revoke_invitation,
)
from app.models._base import utcnow


router = APIRouter(prefix="/api/household", tags=["household"])


def _household_payload(
    *,
    household: Household,
    members: list[HouseholdMember],
    invitations: list[HouseholdInvitation],
    requesting_user_id: str,
) -> dict[str, object]:
    role = "guest"
    for m in members:
        if m.user_id == requesting_user_id:
            role = m.role
            break
    return {
        "household_id": household.id,
        "name": household.name,
        "created_by_user_id": household.created_by_user_id,
        "role": role,
        "members": [
            HouseholdMemberOut(
                user_id=m.user_id,
                role=m.role,
                joined_at=m.joined_at,
            ).model_dump()
            for m in members
        ],
        "active_invitations": [
            HouseholdInvitationOut(
                code=inv.code,
                created_at=inv.created_at,
                expires_at=inv.expires_at,
                created_by_user_id=inv.created_by_user_id,
            ).model_dump()
            for inv in invitations
        ],
    }


def _require_owner(
    session: Session,
    *,
    household_id: str,
    user_id: str,
) -> HouseholdMember:
    """Raise 403 if the user isn't the owner of `household_id`."""
    members = list_members(session, household_id)
    for m in members:
        if m.user_id == user_id and m.role == "owner":
            return m
    raise HTTPException(status_code=403, detail="Only the household owner can do this.")


@router.get("", response_model=HouseholdOut)
def get_household_route(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    household = session.get(Household, current_user.household_id)
    if household is None:
        raise HTTPException(status_code=404, detail="Household not found.")
    members = list_members(session, current_user.household_id)
    invitations = list_active_invitations(session, current_user.household_id)
    return _household_payload(
        household=household,
        members=members,
        invitations=invitations,
        requesting_user_id=current_user.id,
    )


@router.put("", response_model=HouseholdOut)
def rename_household_route(
    payload: HouseholdRenameRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    _require_owner(session, household_id=current_user.household_id, user_id=current_user.id)
    household = session.get(Household, current_user.household_id)
    if household is None:
        raise HTTPException(status_code=404, detail="Household not found.")
    household.name = payload.name.strip()
    household.updated_at = utcnow()
    session.commit()
    members = list_members(session, current_user.household_id)
    invitations = list_active_invitations(session, current_user.household_id)
    return _household_payload(
        household=household,
        members=members,
        invitations=invitations,
        requesting_user_id=current_user.id,
    )


@router.post("/invitations", response_model=InvitationCreatedOut)
def create_invitation_route(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    _require_owner(session, household_id=current_user.household_id, user_id=current_user.id)
    invitation = create_invitation(
        session,
        household_id=current_user.household_id,
        created_by_user_id=current_user.id,
    )
    session.commit()
    return {"code": invitation.code, "expires_at": invitation.expires_at}


@router.delete("/invitations/{code}", status_code=204)
def revoke_invitation_route(
    code: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    _require_owner(session, household_id=current_user.household_id, user_id=current_user.id)
    revoked = revoke_invitation(
        session, code=code, household_id=current_user.household_id
    )
    if not revoked:
        raise HTTPException(status_code=404, detail="Invitation not found or already used.")
    session.commit()
    return Response(status_code=204)


@router.post("/join", response_model=HouseholdOut)
def join_household_route(
    payload: JoinHouseholdRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    try:
        household = claim_invitation(
            session, code=payload.code, joining_user_id=current_user.id
        )
    except InvitationNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except InvitationExpiredError as exc:
        raise HTTPException(status_code=410, detail=str(exc)) from exc
    except InvitationOwnHouseholdError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except InvitationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    session.commit()
    # The joiner's `current_user.household_id` was resolved at request entry —
    # it still points at the (now-deleted) solo household. Re-resolve from
    # the new membership row.
    members = list_members(session, household.id)
    invitations = list_active_invitations(session, household.id)
    return _household_payload(
        household=household,
        members=members,
        invitations=invitations,
        requesting_user_id=current_user.id,
    )
