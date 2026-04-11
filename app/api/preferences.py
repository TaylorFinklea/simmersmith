from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.schemas import (
    MealScoreRequest,
    MealScoreResponse,
    PreferenceBatchUpsertRequest,
    PreferenceContextResponse,
)
from app.services.preferences import preference_context_payload, score_meal_candidate, upsert_preference_signals


router = APIRouter(prefix="/api/preferences", tags=["preferences"])


@router.get("", response_model=PreferenceContextResponse)
def get_preferences(session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    return preference_context_payload(session, current_user.id)


@router.post("", response_model=PreferenceContextResponse)
def post_preferences(
    payload: PreferenceBatchUpsertRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    upsert_preference_signals(session, current_user.id, payload.signals)
    session.commit()
    return preference_context_payload(session, current_user.id)


@router.post("/score-meal", response_model=MealScoreResponse)
def post_score_meal(
    payload: MealScoreRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    return score_meal_candidate(session, current_user.id, payload)
