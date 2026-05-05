from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from pydantic import BaseModel, Field

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings
from app.db import get_session
from app.schemas import (
    DraftFromAIRequest,
    ExportCreateRequest,
    ExportRunOut,
    FeedbackEntryPayload,
    GroceryItemAddRequest,
    GroceryItemOut,
    GroceryItemPatchRequest,
    GroceryListDeltaOut,
    WeekChangeBatchOut,
    WeekFeedbackResponse,
    MealUpdatePayload,
    PricingImportRequest,
    PricingResponse,
    WeekCreateRequest,
    WeekMealSideAddRequest,
    WeekMealSideOut,
    WeekMealSidePatchRequest,
    WeekOut,
    WeekSummaryOut,
)
from app.services.ai import profile_settings_map
from app.services.entitlements import (
    ACTION_AI_GENERATE,
    ACTION_PRICING_FETCH,
    ACTION_REBALANCE_DAY,
    ensure_action_allowed,
    increment_usage,
)
from app.services.drafts import apply_ai_draft, set_week_approved, set_week_ready_for_ai, update_week_meals
from app.services.exports import create_export_run, export_runs_payload
from app.services.feedback import feedback_response_payload, upsert_feedback_entries
from app.services.grocery import (
    add_user_grocery_item,
    dedupe_week_grocery,
    regenerate_grocery_for_week,
    set_grocery_item_checked,
    update_grocery_item,
)
from app.services.sides import add_side, delete_side, update_side
from app.services.presenters import grocery_item_payload, pricing_payload, week_payload, week_summary_payload
from app.services.pricing import import_pricing
from app.services.weeks import create_or_get_week, get_current_week, get_week, get_week_by_start, list_weeks


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/weeks", tags=["weeks"])


def load_week_or_404(session: Session, household_id: str, week_id: str):
    week = get_week(session, household_id, week_id)
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
    return week_summary_payload(list_weeks(session, current_user.household_id, limit=max(1, min(limit, 24))))


@router.get("/current", response_model=WeekOut | None)
def current_week(session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object] | None:
    return week_payload(get_current_week(session, current_user.household_id), session=session)


@router.get("/by-start", response_model=WeekOut | None)
def week_by_start(week_start: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object] | None:
    return week_payload(get_week_by_start(session, current_user.household_id, WeekCreateRequest(week_start=week_start).week_start), session=session)


@router.get("/{week_id}", response_model=WeekOut)
def week_detail(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    return week_payload(load_week_or_404(session, current_user.household_id, week_id), session=session) or {}


@router.post("", response_model=WeekOut)
def create_week(payload: WeekCreateRequest, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = create_or_get_week(
        session,
        user_id=current_user.id,
        household_id=current_user.household_id,
        week_start=payload.week_start,
        notes=payload.notes,
    )
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week.id), session=session) or {}


@router.post("/{week_id}/draft-from-ai", response_model=WeekOut)
def apply_draft(
    week_id: str,
    payload: DraftFromAIRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    apply_ai_draft(session, week, payload)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week.id), session=session) or {}


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

    ensure_action_allowed(session, current_user.id, ACTION_AI_GENERATE)

    week = load_week_or_404(session, current_user.household_id, week_id)
    settings = get_settings()
    user_settings = profile_settings_map(session, current_user.id)

    context = gather_planning_context(session, current_user.id, exclude_week_id=week_id, household_id=current_user.household_id)

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
    increment_usage(session, current_user.id, ACTION_AI_GENERATE)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week.id), session=session) or {}


@router.put("/{week_id}/meals", response_model=WeekOut)
def update_meals(
    week_id: str,
    payload: list[MealUpdatePayload],
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    update_week_meals(session, week, payload)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week.id), session=session) or {}


def _load_meal_or_404(session: Session, household_id: str, week_id: str, meal_id: str):
    """Resolve `(week, meal)` enforcing household ownership in one shot."""
    from app.models import WeekMeal

    week = load_week_or_404(session, household_id, week_id)
    meal = session.scalar(
        select(WeekMeal).where(WeekMeal.id == meal_id, WeekMeal.week_id == week.id)
    )
    if meal is None:
        raise HTTPException(status_code=404, detail="Meal not found")
    return week, meal


def _load_side_or_404(session: Session, household_id: str, week_id: str, meal_id: str, side_id: str):
    from app.models import WeekMealSide

    week, meal = _load_meal_or_404(session, household_id, week_id, meal_id)
    side = session.scalar(
        select(WeekMealSide).where(
            WeekMealSide.id == side_id, WeekMealSide.week_meal_id == meal.id
        )
    )
    if side is None:
        raise HTTPException(status_code=404, detail="Side not found")
    return week, meal, side


def _side_payload(side) -> dict[str, object]:
    return {
        "side_id": side.id,
        "week_meal_id": side.week_meal_id,
        "recipe_id": side.recipe_id,
        "recipe_name": side.recipe.name if side.recipe is not None else None,
        "name": side.name,
        "notes": side.notes,
        "sort_order": side.sort_order,
        "updated_at": side.updated_at,
    }


@router.post("/{week_id}/meals/{meal_id}/sides", response_model=WeekMealSideOut)
def add_side_route(
    week_id: str,
    meal_id: str,
    payload: WeekMealSideAddRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week, meal = _load_meal_or_404(session, current_user.household_id, week_id, meal_id)
    try:
        side = add_side(
            session,
            week=week,
            meal=meal,
            household_id=current_user.household_id,
            name=payload.name,
            recipe_id=payload.recipe_id,
            notes=payload.notes,
            sort_order=payload.sort_order if payload.sort_order > 0 else None,
            user_id=current_user.id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(side)
    return _side_payload(side)


@router.patch("/{week_id}/meals/{meal_id}/sides/{side_id}", response_model=WeekMealSideOut)
def patch_side_route(
    week_id: str,
    meal_id: str,
    side_id: str,
    payload: WeekMealSidePatchRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week, _meal, side = _load_side_or_404(
        session, current_user.household_id, week_id, meal_id, side_id
    )
    fields = payload.model_dump(exclude_unset=True)
    try:
        update_side(
            session,
            week=week,
            side=side,
            household_id=current_user.household_id,
            fields=fields,
            user_id=current_user.id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(side)
    return _side_payload(side)


@router.delete("/{week_id}/meals/{meal_id}/sides/{side_id}", status_code=204)
def delete_side_route(
    week_id: str,
    meal_id: str,
    side_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> None:
    week, _meal, side = _load_side_or_404(
        session, current_user.household_id, week_id, meal_id, side_id
    )
    delete_side(
        session,
        week=week,
        side=side,
        household_id=current_user.household_id,
        user_id=current_user.id,
    )
    session.commit()


class SideAIRecipeRequest(BaseModel):
    """M29 build 53 — generate a recipe draft for a meal side. Routed
    through `RecipeDraftReviewSheet` on iOS, so this endpoint never
    persists. Caller decides via the existing PATCH side route after
    Save."""

    prompt: str = ""
    servings: int = Field(default=0, ge=0, le=200)


@router.post("/{week_id}/meals/{meal_id}/sides/{side_id}/ai-recipe")
def generate_side_recipe_route(
    week_id: str,
    meal_id: str,
    side_id: str,
    payload: SideAIRecipeRequest,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    from app.services.recipe_drafting import generate_recipe_draft_for_dish

    week, meal, side = _load_side_or_404(
        session, current_user.household_id, week_id, meal_id, side_id
    )
    user_settings = profile_settings_map(session, current_user.id)
    # Default servings to the parent meal's servings — sides scale
    # with the main, so this is the right floor when the user
    # doesn't override.
    servings = payload.servings or int(meal.servings or 4)
    try:
        draft = generate_recipe_draft_for_dish(
            settings=settings,
            user_settings=user_settings,
            dish_name=side.name,
            servings=servings,
            user_prompt=payload.prompt,
            constraints_block="",
            context_label=f"a side dish for the meal \"{meal.recipe_name}\" (week of {week.week_start.isoformat()})",
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return draft


@router.get("/{week_id}/changes", response_model=list[WeekChangeBatchOut])
def week_changes(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> list[dict[str, object]]:
    return change_batches_payload(load_week_or_404(session, current_user.household_id, week_id))


@router.post("/{week_id}/ready-for-ai", response_model=WeekOut)
def ready_for_ai(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    set_week_ready_for_ai(session, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week.id), session=session) or {}


@router.post("/{week_id}/approve", response_model=WeekOut)
def approve_week(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    set_week_approved(session, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week.id), session=session) or {}


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

    ensure_action_allowed(session, current_user.id, ACTION_REBALANCE_DAY)

    week = load_week_or_404(session, current_user.household_id, week_id)
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

    context = gather_planning_context(session, current_user.id, exclude_week_id=week_id, household_id=current_user.household_id)

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
    increment_usage(session, current_user.id, ACTION_REBALANCE_DAY)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week_id), session=session) or {}


@router.post("/{week_id}/grocery/regenerate", response_model=WeekOut)
def regenerate_grocery(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    regenerate_grocery_for_week(session, current_user.id, current_user.household_id, week)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week.id), session=session) or {}


@router.post("/{week_id}/grocery/dedupe", response_model=WeekOut)
def dedupe_grocery(
    week_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Collapse duplicate grocery rows on this week — same
    `(normalized_name, unit)` rolls up into the earliest-created row
    with quantities summed; the rest are tombstoned. Triggered by the
    iOS Grocery → Dedupe duplicates action. Idempotent.
    """
    week = load_week_or_404(session, current_user.household_id, week_id)
    counts = dedupe_week_grocery(session, week=week)
    logger.info("dedupe_grocery week=%s counts=%s", week.id, counts)
    session.commit()
    session.expire_all()
    return week_payload(get_week(session, current_user.household_id, week.id), session=session) or {}


def _load_grocery_item_or_404(
    session: Session, household_id: str, week_id: str, item_id: str
):
    """Resolve `(week, item)`, enforcing household ownership in one shot.
    Returns the live ORM objects so callers can mutate them and rely on
    SQLAlchemy's onupdate=utcnow trigger to bump `updated_at`.
    """
    from app.models import GroceryItem

    week = load_week_or_404(session, household_id, week_id)
    item = session.scalar(
        select(GroceryItem).where(
            GroceryItem.id == item_id, GroceryItem.week_id == week.id
        )
    )
    if item is None:
        raise HTTPException(status_code=404, detail="Grocery item not found")
    return week, item


@router.post("/{week_id}/grocery/items", response_model=GroceryItemOut)
def add_grocery_item_route(
    week_id: str,
    payload: GroceryItemAddRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Insert a manually-added grocery item. Smart-merge regen never
    deletes or rewrites these rows — only the user can remove them.
    """
    week = load_week_or_404(session, current_user.household_id, week_id)
    try:
        item = add_user_grocery_item(
            session,
            week=week,
            name=payload.name,
            quantity=payload.quantity,
            unit=payload.unit,
            notes=payload.notes,
            category=payload.category,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(item)
    return grocery_item_payload(item)


@router.patch("/{week_id}/grocery/items/{item_id}", response_model=GroceryItemOut)
def patch_grocery_item_route(
    week_id: str,
    item_id: str,
    payload: GroceryItemPatchRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Update a grocery item. Pydantic's `model_fields_set` lets us tell
    "field absent → leave alone" from "field=null → clear override".
    """
    week, item = _load_grocery_item_or_404(
        session, current_user.household_id, week_id, item_id
    )
    fields = payload.model_dump(exclude_unset=True)
    update_grocery_item(session, week=week, item=item, fields=fields)
    session.commit()
    session.refresh(item)
    return grocery_item_payload(item)


@router.post("/{week_id}/grocery/items/{item_id}/check", response_model=GroceryItemOut)
def check_grocery_item_route(
    week_id: str,
    item_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week, item = _load_grocery_item_or_404(
        session, current_user.household_id, week_id, item_id
    )
    set_grocery_item_checked(
        session, week=week, item=item, user_id=current_user.id, checked=True
    )
    session.commit()
    session.refresh(item)
    return grocery_item_payload(item)


@router.delete("/{week_id}/grocery/items/{item_id}/check", response_model=GroceryItemOut)
def uncheck_grocery_item_route(
    week_id: str,
    item_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week, item = _load_grocery_item_or_404(
        session, current_user.household_id, week_id, item_id
    )
    set_grocery_item_checked(
        session, week=week, item=item, user_id=current_user.id, checked=False
    )
    session.commit()
    session.refresh(item)
    return grocery_item_payload(item)


@router.get("/{week_id}/grocery", response_model=GroceryListDeltaOut)
def grocery_delta_route(
    week_id: str,
    since: str | None = None,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Return the week's grocery items, optionally filtered to
    `updated_at > since`. Includes tombstones (`is_user_removed=True`)
    so iOS Reminders sync can detect and propagate removals it hasn't
    yet mirrored locally. The returned `server_time` is what callers
    should pass back as `since` on the next poll.
    """
    from datetime import datetime, timezone

    from app.models import GroceryItem

    week = load_week_or_404(session, current_user.household_id, week_id)
    statement = select(GroceryItem).where(GroceryItem.week_id == week.id)
    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="invalid `since`") from exc
        statement = statement.where(GroceryItem.updated_at > since_dt)
    items = list(session.scalars(statement).all())
    return {
        "week_id": week.id,
        "server_time": datetime.now(timezone.utc),
        "items": [grocery_item_payload(item) for item in items],
    }


@router.get("/{week_id}/feedback", response_model=WeekFeedbackResponse)
def week_feedback(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    return feedback_response_payload(session, week)


@router.post("/{week_id}/feedback", response_model=WeekFeedbackResponse)
def save_week_feedback(
    week_id: str,
    payload: list[FeedbackEntryPayload],
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    upsert_feedback_entries(session, current_user.id, week, payload)
    session.commit()
    session.expire_all()
    refreshed_week = load_week_or_404(session, current_user.household_id, week_id)
    return feedback_response_payload(session, refreshed_week)


@router.get("/{week_id}/pricing", response_model=PricingResponse)
def pricing_detail(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
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

    ensure_action_allowed(session, current_user.id, ACTION_PRICING_FETCH)

    week = load_week_or_404(session, current_user.household_id, week_id)
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
    increment_usage(session, current_user.id, ACTION_PRICING_FETCH)
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
    week = load_week_or_404(session, current_user.household_id, week_id)
    try:
        result = import_pricing(session, week, payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.expire_all()
    return result


@router.get("/{week_id}/exports", response_model=list[ExportRunOut])
def week_exports(week_id: str, session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> list[dict[str, object]]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    return export_runs_payload(session, week.id)


@router.post("/{week_id}/exports", response_model=ExportRunOut)
def create_week_export(
    week_id: str,
    payload: ExportCreateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    week = load_week_or_404(session, current_user.household_id, week_id)
    try:
        result = create_export_run(session, week, payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.expire_all()
    return result
