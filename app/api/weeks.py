from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.schemas import (
    DraftFromAIRequest,
    ExportCreateRequest,
    ExportRunOut,
    FeedbackEntryPayload,
    WeekChangeBatchOut,
    WeekFeedbackResponse,
    MealUpdatePayload,
    PricingImportRequest,
    PricingResponse,
    WeekCreateRequest,
    WeekOut,
    WeekSummaryOut,
)
from app.services.drafts import apply_ai_draft, set_week_approved, set_week_ready_for_ai, update_week_meals
from app.services.exports import create_export_run, export_runs_payload
from app.services.feedback import feedback_response_payload, upsert_feedback_entries
from app.services.grocery import regenerate_grocery_for_week
from app.services.presenters import pricing_payload, week_payload, week_summary_payload
from app.services.pricing import import_pricing
from app.services.weeks import create_or_get_week, get_current_week, get_week, get_week_by_start, list_weeks


router = APIRouter(prefix="/api/weeks", tags=["weeks"])


def load_week_or_404(session: Session, user_id: str, week_id: str):
    week = get_week(session, user_id, week_id)
    if week is None:
        raise HTTPException(status_code=404, detail="Week not found")
    return week


def change_batches_payload(week) -> list[dict[str, object]]:
    return [
        {
            "change_batch_id": batch.id,
            "actor_type": batch.actor_type,
            "actor_label": batch.actor_label,
            "summary": batch.summary,
            "created_at": batch.created_at,
            "events": [
                {
                    "change_event_id": event.id,
                    "entity_type": event.entity_type,
                    "entity_id": event.entity_id,
                    "field_name": event.field_name,
                    "before_value": event.before_value,
                    "after_value": event.after_value,
                    "created_at": event.created_at,
                }
                for event in batch.events
            ],
        }
        for batch in week.change_batches
    ]


@router.get("", response_model=list[WeekSummaryOut])
def week_list(limit: int = 6, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> list[dict[str, object]]:
    return week_summary_payload(list_weeks(session, current_user.id, limit=max(1, min(limit, 24))))


@router.get("/current", response_model=WeekOut | None)
def current_week(session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object] | None:
    return week_payload(get_current_week(session, current_user.id))


@router.get("/by-start", response_model=WeekOut | None)
def week_by_start(week_start: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object] | None:
    return week_payload(get_week_by_start(session, current_user.id, WeekCreateRequest(week_start=week_start).week_start))


@router.get("/{week_id}", response_model=WeekOut)
def week_detail(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    return week_payload(load_week_or_404(session, current_user.id, week_id)) or {}


@router.post("", response_model=WeekOut)
def create_week(payload: WeekCreateRequest, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = create_or_get_week(session, current_user.id, payload.week_start, payload.notes)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week.id)) or {}


@router.post("/{week_id}/draft-from-ai", response_model=WeekOut)
def apply_draft(
    week_id: str,
    payload: DraftFromAIRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    apply_ai_draft(session, week, payload)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week_id)) or {}


@router.put("/{week_id}/meals", response_model=WeekOut)
def update_meals(
    week_id: str,
    payload: list[MealUpdatePayload],
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    update_week_meals(session, week, payload)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week_id)) or {}


@router.get("/{week_id}/changes", response_model=list[WeekChangeBatchOut])
def week_changes(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> list[dict[str, object]]:
    return change_batches_payload(load_week_or_404(session, current_user.id, week_id))


@router.post("/{week_id}/ready-for-ai", response_model=WeekOut)
def ready_for_ai(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    set_week_ready_for_ai(session, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week_id)) or {}


@router.post("/{week_id}/approve", response_model=WeekOut)
def approve_week(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    set_week_approved(session, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week_id)) or {}


@router.post("/{week_id}/grocery/regenerate", response_model=WeekOut)
def regenerate_grocery(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    regenerate_grocery_for_week(session, current_user.id, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week_id)) or {}


@router.get("/{week_id}/feedback", response_model=WeekFeedbackResponse)
def week_feedback(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    return feedback_response_payload(session, week)


@router.post("/{week_id}/feedback", response_model=WeekFeedbackResponse)
def save_week_feedback(
    week_id: str,
    payload: list[FeedbackEntryPayload],
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    upsert_feedback_entries(session, current_user.id, week, payload)
    session.commit()
    session.expire_all()
    refreshed_week = load_week_or_404(session, current_user.id, week_id)
    return feedback_response_payload(session, refreshed_week)


@router.get("/{week_id}/pricing", response_model=PricingResponse)
def pricing_detail(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    payload = pricing_payload(week)
    return payload or {"week_id": week.id, "week_start": week.week_start, "totals": {}, "items": []}


@router.post("/{week_id}/pricing/import", response_model=PricingResponse)
def import_week_pricing(
    week_id: str,
    payload: PricingImportRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    try:
        result = import_pricing(session, week, payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.expire_all()
    return result


@router.get("/{week_id}/exports", response_model=list[ExportRunOut])
def week_exports(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> list[dict[str, object]]:
    week = load_week_or_404(session, current_user.id, week_id)
    return export_runs_payload(session, week.id)


@router.post("/{week_id}/exports", response_model=ExportRunOut)
def create_week_export(
    week_id: str,
    payload: ExportCreateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    try:
        result = create_export_run(session, week, payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.expire_all()
    return result
