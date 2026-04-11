from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.schemas import ProfileResponse, ProfileUpdateRequest
from app.services.presenters import profile_payload
from app.services.profile import update_profile


router = APIRouter(prefix="/api/profile", tags=["profile"])


@router.get("", response_model=ProfileResponse)
def get_profile(session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    return profile_payload(session, current_user.id)


@router.put("", response_model=ProfileResponse)
def put_profile(
    payload: ProfileUpdateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    update_profile(session, current_user.id, payload.settings, payload.staples)
    session.commit()
    return profile_payload(session, current_user.id)
