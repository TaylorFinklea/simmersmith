from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.schemas import DietaryGoalOut, DietaryGoalPayload, ProfileResponse, ProfileUpdateRequest
from app.services.presenters import dietary_goal_payload, profile_payload
from app.services.profile import delete_dietary_goal, get_dietary_goal, update_profile, upsert_dietary_goal


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


@router.get("/dietary-goal", response_model=DietaryGoalOut | None)
def read_dietary_goal(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object] | None:
    return dietary_goal_payload(get_dietary_goal(session, current_user.id))


@router.put("/dietary-goal", response_model=DietaryGoalOut)
def put_dietary_goal(
    payload: DietaryGoalPayload,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    goal = upsert_dietary_goal(session, current_user.id, payload)
    session.commit()
    serialized = dietary_goal_payload(goal)
    assert serialized is not None
    return serialized


@router.delete("/dietary-goal", status_code=status.HTTP_204_NO_CONTENT)
def clear_dietary_goal(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    delete_dietary_goal(session, current_user.id)
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
