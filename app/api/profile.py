from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.db import get_session
from app.schemas import ProfileResponse, ProfileUpdateRequest
from app.services.presenters import profile_payload
from app.services.profile import update_profile


router = APIRouter(prefix="/api/profile", tags=["profile"])


@router.get("", response_model=ProfileResponse)
def get_profile(session: Session = Depends(get_session)) -> dict[str, object]:
    return profile_payload(session)


@router.put("", response_model=ProfileResponse)
def put_profile(
    payload: ProfileUpdateRequest,
    session: Session = Depends(get_session),
) -> dict[str, object]:
    update_profile(session, payload.settings, payload.staples)
    session.commit()
    return profile_payload(session)
