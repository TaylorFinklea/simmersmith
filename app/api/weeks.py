from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from pydantic import BaseModel

from app.auth import CurrentUser, get_current_user
from app.config import get_settings
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
from app.services.ai import profile_settings_map
from app.services.drafts import apply_ai_draft, set_week_approved, set_week_ready_for_ai, update_week_meals
from app.services.exports import create_export_run, export_runs_payload
from app.services.feedback import feedback_response_payload, upsert_feedback_entries
from app.services.grocery import regenerate_grocery_for_week
from app.services.presenters import pricing_payload, week_payload, week_summary_payload
from app.services.pricing import import_pricing
from app.services.weeks import create_or_get_week, get_current_week, get_week, get_week_by_start, list_weeks


logger = logging.getLogger(__name__)
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
    return week_payload(get_current_week(session, current_user.id), session=session)


@router.get("/by-start", response_model=WeekOut | None)
def week_by_start(week_start: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object] | None:
    return week_payload(get_week_by_start(session, current_user.id, WeekCreateRequest(week_start=week_start).week_start), session=session)


@router.get("/{week_id}", response_model=WeekOut)
def week_detail(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    return week_payload(load_week_or_404(session, current_user.id, week_id), session=session) or {}


@router.post("", response_model=WeekOut)
def create_week(payload: WeekCreateRequest, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = create_or_get_week(session, current_user.id, payload.week_start, payload.notes)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week.id), session=session) or {}


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
    return week_payload(get_week(session, current_user.id, week.id), session=session) or {}


class GenerateWeekRequest(BaseModel):
    prompt: str = ""


@router.post("/{week_id}/generate", response_model=WeekOut)
def generate_week_plan(
    week_id: str,
    payload: GenerateWeekRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Generate a full week of meals using AI."""
    from app.services.week_planner import (
        gather_planning_context,
        generate_week_plan as run_planner,
        score_generated_plan,
    )

    week = load_week_or_404(session, current_user.id, week_id)
    settings = get_settings()
    user_settings = profile_settings_map(session, current_user.id)

    context = gather_planning_context(session, current_user.id, exclude_week_id=week_id)

    try:
        draft_data = run_planner(
            settings=settings,
            user_settings=user_settings,
            user_prompt=payload.prompt,
            week_start=week.week_start,
            planning_context=context,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    scores = score_generated_plan(session, current_user.id, draft_data)
    if scores["blocked_meals"]:
        notes = draft_data.get("week_notes", "")
        blocked_note = f"Blocked meals: {', '.join(scores['blocked_meals'])}"
        draft_data["week_notes"] = f"{notes}; {blocked_note}" if notes else blocked_note
    macro_flags = scores.get("macro_flags") or []
    if macro_flags:
        notes = draft_data.get("week_notes", "")
        drift_note = (
            "Days off calorie target: "
            + ", ".join(
                f"{flag['day_name'] or flag['meal_date']} ({flag['drift_pct']:+.0f}%)"
                for flag in macro_flags
            )
        )
        draft_data["week_notes"] = f"{notes}; {drift_note}" if notes else drift_note
    logger.info(
        "Plan score: %s (blocked: %s, macro_flags: %s)",
        scores["plan_total_score"], scores["blocked_meals"], macro_flags,
    )

    draft = DraftFromAIRequest.model_validate(draft_data)
    apply_ai_draft(session, week, draft)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week.id), session=session) or {}


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
    return week_payload(get_week(session, current_user.id, week.id), session=session) or {}


@router.get("/{week_id}/changes", response_model=list[WeekChangeBatchOut])
def week_changes(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> list[dict[str, object]]:
    return change_batches_payload(load_week_or_404(session, current_user.id, week_id))


@router.post("/{week_id}/ready-for-ai", response_model=WeekOut)
def ready_for_ai(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    set_week_ready_for_ai(session, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week.id), session=session) or {}


@router.post("/{week_id}/approve", response_model=WeekOut)
def approve_week(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    set_week_approved(session, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week.id), session=session) or {}


class RebalanceDayRequest(BaseModel):
    meal_date: str  # YYYY-MM-DD


@router.post("/{week_id}/days/rebalance", response_model=WeekOut)
def rebalance_day_endpoint(
    week_id: str,
    payload: RebalanceDayRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Regenerate a single day's meals to hit the dietary goal.

    Keeps the rest of the week untouched. Requires the user to have a
    dietary goal set (422 otherwise — rebalancing without a target makes no
    sense).
    """
    from datetime import date as _date

    from app.models import WeekMeal, WeekMealIngredient
    from app.services.profile import get_dietary_goal
    from app.services.week_planner import (
        gather_planning_context,
        rebalance_day as run_rebalance,
    )

    week = load_week_or_404(session, current_user.id, week_id)
    settings = get_settings()
    user_settings = profile_settings_map(session, current_user.id)

    goal = get_dietary_goal(session, current_user.id)
    if goal is None or goal.daily_calories <= 0:
        raise HTTPException(
            status_code=422,
            detail="Set a dietary goal before rebalancing a day.",
        )

    try:
        target_date = _date.fromisoformat(payload.meal_date)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=f"Invalid meal_date: {payload.meal_date}") from exc

    context = gather_planning_context(session, current_user.id, exclude_week_id=week_id)

    # Delete the existing meals + inline ingredients for that day.
    existing = [m for m in week.meals if m.meal_date == target_date]
    day_name = existing[0].day_name if existing else ""
    if not day_name:
        # Fall back to weekday name so the prompt + new meals stay consistent.
        day_name = target_date.strftime("%A")
    for meal in existing:
        session.execute(
            WeekMealIngredient.__table__.delete().where(WeekMealIngredient.meal_id == meal.id)
        )
        session.execute(WeekMeal.__table__.delete().where(WeekMeal.id == meal.id))
    session.flush()

    try:
        draft_data = run_rebalance(
            settings=settings,
            user_settings=user_settings,
            week_start=week.week_start,
            target_date=target_date,
            day_name=day_name,
            planning_context=context,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    draft = DraftFromAIRequest.model_validate(draft_data)
    apply_ai_draft(session, week, draft)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week_id), session=session) or {}


@router.post("/{week_id}/grocery/regenerate", response_model=WeekOut)
def regenerate_grocery(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.id, week_id)
    regenerate_grocery_for_week(session, current_user.id, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.id, week.id), session=session) or {}


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


class FetchPricingRequest(BaseModel):
    location_id: str = ""


@router.post("/{week_id}/pricing/fetch", response_model=PricingResponse)
def fetch_week_pricing(
    week_id: str,
    payload: FetchPricingRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Fetch live grocery prices from Kroger API for a week's grocery list."""
    from app.services.pricing import fetch_kroger_pricing

    week = load_week_or_404(session, current_user.id, week_id)
    settings = get_settings()

    # Resolve store: explicit request > profile setting > error
    location_id = payload.location_id
    if not location_id:
        user_settings = profile_settings_map(session, current_user.id)
        location_id = user_settings.get("kroger_location_id", "")
    if not location_id:
        raise HTTPException(
            status_code=400,
            detail="No store selected. Pass location_id or set kroger_location_id in profile settings.",
        )

    try:
        result = fetch_kroger_pricing(session, week, settings, location_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    session.commit()
    session.expire_all()
    return result


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
