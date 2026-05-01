"""Tool registry for the conversational planning assistant (M6).

Each tool wraps an existing service function with a JSON schema the LLM can
call against. Mutating tools reuse the same gating (ensure_action_allowed +
increment_usage) as the HTTP endpoints, so free-tier limits apply whether a
user taps the button or the AI calls the tool.

Tools that mutate the current week return the refreshed `week_payload` so the
calling endpoint can stream a `week.updated` SSE event without the client
having to re-fetch.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import date as _date
from typing import Any, Callable

from sqlalchemy.orm import Session

from app.config import Settings
from app.models import Week, WeekMeal, WeekMealIngredient
from sqlalchemy import delete as sa_delete
from app.schemas import DietaryGoalPayload, DraftFromAIRequest, MealUpdatePayload
from app.services.ai import profile_settings_map
from app.services.drafts import apply_ai_draft, update_week_meals
from app.services.entitlements import (
    ACTION_AI_GENERATE,
    ACTION_PRICING_FETCH,
    ACTION_REBALANCE_DAY,
    ensure_action_allowed,
    increment_usage,
)
from app.services.presenters import week_payload
from app.services.profile import get_dietary_goal, upsert_dietary_goal
from app.services.weeks import get_current_week, get_week

logger = logging.getLogger(__name__)

MAX_TOOL_ITERATIONS = 6


@dataclass(frozen=True)
class AssistantToolResult:
    ok: bool
    detail: str
    week: dict[str, object] | None = None
    data: dict[str, object] = field(default_factory=dict)

    def to_model_reply(self) -> dict[str, object]:
        """Compact form to feed back to the model as the tool's return value."""
        body: dict[str, object] = {"ok": self.ok, "detail": self.detail}
        if self.data:
            body["data"] = self.data
        if self.week is not None:
            body["week_summary"] = _compact_week_summary(self.week)
        return body


@dataclass(frozen=True)
class AssistantTool:
    name: str
    description: str
    parameters_schema: dict[str, object]
    mutates_week: bool
    gated_action: str | None
    runner: Callable[..., AssistantToolResult]


# --- Helpers --------------------------------------------------------------


def _resolve_week(session: Session, household_id: str, linked_week_id: str | None) -> Week | None:
    if linked_week_id:
        week = get_week(session, household_id, linked_week_id)
        if week is not None:
            return week
    return get_current_week(session, household_id)


def _week_payload_dict(session: Session, household_id: str, week_id: str) -> dict[str, object] | None:
    # Expire so collections (meals, grocery_items, etc.) re-load from DB after flush.
    session.expire_all()
    fresh = get_week(session, household_id, week_id)
    if fresh is None:
        return None
    return week_payload(fresh, session=session)


def _compact_week_summary(payload: dict[str, object]) -> dict[str, object]:
    """Trim a full week payload to what's useful for the LLM's next turn."""
    meals_summary: list[dict[str, object]] = []
    for meal in payload.get("meals", []) or []:  # type: ignore[assignment]
        if not isinstance(meal, dict):
            continue
        meals_summary.append(
            {
                "meal_id": meal.get("meal_id"),
                "day_name": meal.get("day_name"),
                "meal_date": meal.get("meal_date"),
                "slot": meal.get("slot"),
                "recipe_name": meal.get("recipe_name"),
                "approved": meal.get("approved"),
            }
        )
    return {
        "week_id": payload.get("week_id"),
        "week_start": payload.get("week_start"),
        "status": payload.get("status"),
        "meals": meals_summary,
    }


def _as_meal_update(meal: Any, **overrides: Any) -> MealUpdatePayload:
    base: dict[str, Any] = {
        "meal_id": meal.id,
        "day_name": meal.day_name,
        "meal_date": meal.meal_date,
        "slot": meal.slot,
        "recipe_id": meal.recipe_id,
        "recipe_name": meal.recipe_name,
        "servings": meal.servings,
        "scale_multiplier": meal.scale_multiplier,
        "notes": meal.notes,
        "approved": meal.approved,
    }
    base.update(overrides)
    return MealUpdatePayload(**base)


def _parse_meal_date(raw: str | None) -> _date | None:
    if not raw:
        return None
    try:
        return _date.fromisoformat(str(raw))
    except ValueError:
        return None


# --- Tool runners ---------------------------------------------------------


def _run_get_current_week(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    del args, settings
    if week is None:
        return AssistantToolResult(ok=False, detail="No active week. Create one first.")
    payload = week_payload(week, session=session) or {}
    return AssistantToolResult(
        ok=True,
        detail=f"Loaded week {payload.get('week_start')}.",
        week=payload,
    )


def _run_get_preferences_summary(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    from app.services.preferences import preference_summary_payload

    del args, week, settings
    summary = preference_summary_payload(session, user_id)
    parts: list[str] = []
    if summary.get("hard_avoids"):
        parts.append("avoid " + ", ".join(summary["hard_avoids"]))
    if summary.get("strong_likes"):
        parts.append("loves " + ", ".join(summary["strong_likes"]))
    if summary.get("rules"):
        parts.append("rules: " + "; ".join(summary["rules"]))
    detail = "; ".join(parts) if parts else "No strong preferences recorded yet."
    return AssistantToolResult(ok=True, detail=detail, data={"summary": summary})


def _run_get_dietary_goal(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    del args, week, settings
    goal = get_dietary_goal(session, user_id)
    if goal is None:
        return AssistantToolResult(ok=True, detail="No dietary goal set.", data={"goal": None})
    return AssistantToolResult(
        ok=True,
        detail=f"{goal.goal_type.capitalize()} goal at {goal.daily_calories} kcal/day.",
        data={
            "goal": {
                "goal_type": goal.goal_type,
                "daily_calories": goal.daily_calories,
                "protein_g": goal.protein_g,
                "carbs_g": goal.carbs_g,
                "fat_g": goal.fat_g,
                "fiber_g": goal.fiber_g,
            }
        },
    )


def _run_generate_week_plan(
    *,
    session: Session,
    user_id: str,
    household_id: str,
    week: Week | None,
    args: dict,
    settings: Settings,
    on_event: Callable[[str, dict[str, object]], None] | None = None,
) -> AssistantToolResult:
    from app.services.week_planner import gather_planning_context, generate_week_plan

    if week is None:
        return AssistantToolResult(ok=False, detail="No active week. Create one first.")

    user_prompt = str(args.get("prompt") or "Plan a balanced, varied week of meals.").strip()
    context = gather_planning_context(session, user_id, exclude_week_id=week.id)
    user_settings = profile_settings_map(session, user_id)

    try:
        plan = generate_week_plan(
            settings=settings,
            user_settings=user_settings,
            user_prompt=user_prompt,
            week_start=week.week_start,
            planning_context=context,
        )
    except RuntimeError as exc:
        return AssistantToolResult(ok=False, detail=f"Planner failed: {exc}")

    draft = DraftFromAIRequest.model_validate(plan)

    # Apply day-by-day so the iOS client can show meals appearing
    # progressively rather than all at once. The AI call is still one
    # shot (the model returns the full week in a single response), but
    # applying each day in its own commit + emitting week.updated gives
    # the user a sense of progress while grocery/nutrition recomputation
    # happens.
    if on_event is None:
        apply_ai_draft(session, week, draft)
        session.flush()
        payload = _week_payload_dict(session, household_id, week.id) or {}
        meal_count = len(payload.get("meals") or [])
        return AssistantToolResult(
            ok=True,
            detail=f"Planned the week with {meal_count} meals.",
            week=payload,
        )

    meal_count = _apply_week_plan_incrementally(
        session=session,
        user_id=user_id,
        household_id=household_id,
        week=week,
        draft=draft,
        on_event=on_event,
    )
    payload = _week_payload_dict(session, household_id, week.id) or {}
    return AssistantToolResult(
        ok=True,
        detail=f"Planned the week with {meal_count} meals.",
        week=payload,
    )


def _apply_week_plan_incrementally(
    *,
    session: Session,
    user_id: str,
    household_id: str,
    week: Week,
    draft: DraftFromAIRequest,
    on_event: Callable[[str, dict[str, object]], None],
) -> int:
    """Apply an AI draft day-by-day, emitting week.updated between each day.

    The heavy lifting (recipe upserts, grocery regen, change log) still runs
    in `apply_ai_draft` — we just commit per-day partial state first so the
    client can render a progressive reveal while the full commit finishes.
    """
    # Group draft meals by day.
    by_day: dict[str, list] = {}
    for meal in draft.meal_plan:
        key = meal.meal_date.isoformat() if hasattr(meal.meal_date, "isoformat") else str(meal.meal_date)
        by_day.setdefault(key, []).append(meal)

    # Clear existing meals so we can add the new ones day by day.
    session.execute(sa_delete(WeekMeal).where(WeekMeal.week_id == week.id))
    session.flush()

    meal_count = 0
    for day_key in sorted(by_day.keys()):
        for meal in by_day[day_key]:
            session.add(
                WeekMeal(
                    week_id=week.id,
                    day_name=meal.day_name,
                    meal_date=meal.meal_date,
                    slot=meal.slot,
                    recipe_id=meal.recipe_id,
                    recipe_name=meal.recipe_name,
                    servings=meal.servings,
                    scale_multiplier=1.0,
                    source=meal.source,
                    approved=False,
                    notes=meal.notes,
                    ai_generated=True,
                    sort_order=0,
                )
            )
            meal_count += 1
        session.flush()
        partial_payload = _week_payload_dict(session, household_id, week.id) or {}
        on_event("week.updated", {"week": partial_payload})

    # Now run the full apply pipeline. It'll delete the placeholder meals we
    # inserted above and re-insert them with ingredient resolution + grocery
    # regeneration + change history. The final week.updated event emits the
    # authoritative state.
    apply_ai_draft(session, week, draft)
    session.flush()
    return meal_count


def _run_add_meal(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    del settings
    if week is None:
        return AssistantToolResult(ok=False, detail="No active week.")
    day_name = str(args.get("day_name") or "").strip()
    slot = str(args.get("slot") or "").strip().lower() or "dinner"
    recipe_name = str(args.get("recipe_name") or "").strip()
    meal_date = _parse_meal_date(args.get("meal_date"))
    if not day_name or not recipe_name or meal_date is None:
        return AssistantToolResult(ok=False, detail="Need day_name, meal_date (YYYY-MM-DD) and recipe_name.")

    existing = [_as_meal_update(m) for m in week.meals]
    existing.append(
        MealUpdatePayload(
            meal_id=None,
            day_name=day_name,
            meal_date=meal_date,
            slot=slot,
            recipe_name=recipe_name,
            notes=str(args.get("notes") or ""),
            approved=bool(args.get("approved", False)),
        )
    )
    update_week_meals(session, week, existing)
    session.flush()
    payload = _week_payload_dict(session, household_id, week.id) or {}
    return AssistantToolResult(ok=True, detail=f"Added {recipe_name} to {day_name} {slot}.", week=payload)


def _find_meal(week: Week, *, meal_id: str | None, day_name: str | None, slot: str | None) -> Any | None:
    if meal_id:
        for meal in week.meals:
            if meal.id == meal_id:
                return meal
    if day_name and slot:
        want_slot = slot.strip().lower()
        for meal in week.meals:
            if meal.day_name.strip().lower() == day_name.strip().lower() and meal.slot.strip().lower() == want_slot:
                return meal
    return None


def _run_swap_meal(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    del settings
    if week is None:
        return AssistantToolResult(ok=False, detail="No active week.")
    meal = _find_meal(
        week,
        meal_id=str(args.get("meal_id") or "") or None,
        day_name=str(args.get("day_name") or "") or None,
        slot=str(args.get("slot") or "") or None,
    )
    if meal is None:
        return AssistantToolResult(ok=False, detail="Couldn't find that meal.")
    new_name = str(args.get("recipe_name") or "").strip()
    if not new_name:
        return AssistantToolResult(ok=False, detail="recipe_name is required.")

    updates = [
        _as_meal_update(
            m,
            recipe_id=None if m.id == meal.id else m.recipe_id,
            recipe_name=new_name if m.id == meal.id else m.recipe_name,
            notes=str(args.get("notes") or m.notes) if m.id == meal.id else m.notes,
        )
        for m in week.meals
    ]
    update_week_meals(session, week, updates)
    session.flush()
    payload = _week_payload_dict(session, household_id, week.id) or {}
    return AssistantToolResult(
        ok=True,
        detail=f"Swapped {meal.day_name} {meal.slot} to {new_name}.",
        week=payload,
    )


def _run_remove_meal(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    del settings
    if week is None:
        return AssistantToolResult(ok=False, detail="No active week.")
    meal = _find_meal(
        week,
        meal_id=str(args.get("meal_id") or "") or None,
        day_name=str(args.get("day_name") or "") or None,
        slot=str(args.get("slot") or "") or None,
    )
    if meal is None:
        return AssistantToolResult(ok=False, detail="Couldn't find that meal.")
    updates = [_as_meal_update(m) for m in week.meals if m.id != meal.id]
    update_week_meals(session, week, updates)
    session.flush()
    payload = _week_payload_dict(session, household_id, week.id) or {}
    return AssistantToolResult(
        ok=True,
        detail=f"Removed {meal.day_name} {meal.slot}.",
        week=payload,
    )


def _run_set_meal_approved(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    del settings
    if week is None:
        return AssistantToolResult(ok=False, detail="No active week.")
    meal = _find_meal(
        week,
        meal_id=str(args.get("meal_id") or "") or None,
        day_name=str(args.get("day_name") or "") or None,
        slot=str(args.get("slot") or "") or None,
    )
    if meal is None:
        return AssistantToolResult(ok=False, detail="Couldn't find that meal.")
    approved = bool(args.get("approved", True))
    updates = [
        _as_meal_update(m, approved=approved if m.id == meal.id else m.approved)
        for m in week.meals
    ]
    update_week_meals(session, week, updates)
    session.flush()
    payload = _week_payload_dict(session, household_id, week.id) or {}
    verb = "approved" if approved else "unapproved"
    return AssistantToolResult(
        ok=True,
        detail=f"{verb.capitalize()} {meal.day_name} {meal.slot}.",
        week=payload,
    )


def _run_rebalance_day(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    from app.services.week_planner import gather_planning_context, rebalance_day as run_rebalance

    if week is None:
        return AssistantToolResult(ok=False, detail="No active week.")
    target_date = _parse_meal_date(args.get("meal_date"))
    if target_date is None:
        return AssistantToolResult(ok=False, detail="meal_date (YYYY-MM-DD) is required.")

    goal = get_dietary_goal(session, user_id)
    if goal is None or goal.daily_calories <= 0:
        return AssistantToolResult(
            ok=False,
            detail="Set a dietary goal before rebalancing a day.",
        )

    user_settings = profile_settings_map(session, user_id)
    context = gather_planning_context(session, user_id, exclude_week_id=week.id)

    existing = [m for m in week.meals if m.meal_date == target_date]
    day_name = existing[0].day_name if existing else target_date.strftime("%A")
    for meal in existing:
        session.execute(
            WeekMealIngredient.__table__.delete().where(WeekMealIngredient.week_meal_id == meal.id)
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
        return AssistantToolResult(ok=False, detail=f"Rebalance failed: {exc}")

    draft = DraftFromAIRequest.model_validate(draft_data)
    apply_ai_draft(session, week, draft)
    session.flush()
    payload = _week_payload_dict(session, household_id, week.id) or {}
    return AssistantToolResult(
        ok=True,
        detail=f"Rebalanced {day_name} to hit your dietary goal.",
        week=payload,
    )


def _run_fetch_pricing(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    from app.services.pricing import fetch_kroger_pricing

    if week is None:
        return AssistantToolResult(ok=False, detail="No active week.")
    location_id = str(args.get("location_id") or "").strip()
    if not location_id:
        user_settings = profile_settings_map(session, user_id)
        location_id = str(user_settings.get("kroger_location_id") or "").strip()
    if not location_id:
        return AssistantToolResult(
            ok=False,
            detail="No store selected. Ask the user to pick a Kroger store first.",
        )
    if week.status not in {"approved", "priced"}:
        return AssistantToolResult(
            ok=False,
            detail="Approve the week before fetching prices.",
        )
    try:
        fetch_kroger_pricing(session, week, settings, location_id)
    except ValueError as exc:
        return AssistantToolResult(ok=False, detail=str(exc))
    except RuntimeError as exc:
        return AssistantToolResult(ok=False, detail=f"Pricing lookup failed: {exc}")
    session.flush()
    payload = _week_payload_dict(session, household_id, week.id) or {}
    return AssistantToolResult(ok=True, detail="Fetched Kroger prices for the week.", week=payload)


def _run_set_dietary_goal(
    *, session: Session, user_id: str, household_id: str, week: Week | None, args: dict, settings: Settings
) -> AssistantToolResult:
    del week, settings
    try:
        payload = DietaryGoalPayload.model_validate(
            {
                "goal_type": str(args.get("goal_type") or "maintain"),
                "daily_calories": int(args.get("daily_calories") or 0),
                "protein_g": int(args.get("protein_g") or 0),
                "carbs_g": int(args.get("carbs_g") or 0),
                "fat_g": int(args.get("fat_g") or 0),
                "fiber_g": args.get("fiber_g"),
                "notes": str(args.get("notes") or ""),
            }
        )
    except Exception as exc:
        return AssistantToolResult(ok=False, detail=f"Invalid goal: {exc}")
    goal = upsert_dietary_goal(session, user_id, payload)
    session.flush()
    return AssistantToolResult(
        ok=True,
        detail=f"Set {goal.goal_type} goal at {goal.daily_calories} kcal/day.",
    )


# --- Registry -------------------------------------------------------------


REGISTRY: dict[str, AssistantTool] = {
    "get_current_week": AssistantTool(
        name="get_current_week",
        description="Read the user's current week plan (meals, status, dietary drift).",
        parameters_schema={"type": "object", "properties": {}, "additionalProperties": False},
        mutates_week=False,
        gated_action=None,
        runner=_run_get_current_week,
    ),
    "get_dietary_goal": AssistantTool(
        name="get_dietary_goal",
        description="Read the user's current dietary goal (calories + macros).",
        parameters_schema={"type": "object", "properties": {}, "additionalProperties": False},
        mutates_week=False,
        gated_action=None,
        runner=_run_get_dietary_goal,
    ),
    "get_preferences_summary": AssistantTool(
        name="get_preferences_summary",
        description="Read the user's taste preferences — likes, dislikes, hard avoids, household rules.",
        parameters_schema={"type": "object", "properties": {}, "additionalProperties": False},
        mutates_week=False,
        gated_action=None,
        runner=_run_get_preferences_summary,
    ),
    "generate_week_plan": AssistantTool(
        name="generate_week_plan",
        description=(
            "Replan the entire week from scratch using AI. Use this only when the "
            "user asks for a wholesale replan — prefer add/swap/remove for smaller tweaks."
        ),
        parameters_schema={
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "What the user wants out of the week (diet, tastes, constraints).",
                }
            },
            "required": ["prompt"],
            "additionalProperties": False,
        },
        mutates_week=True,
        gated_action=ACTION_AI_GENERATE,
        runner=_run_generate_week_plan,
    ),
    "add_meal": AssistantTool(
        name="add_meal",
        description="Add a meal to a specific day + slot in the current week.",
        parameters_schema={
            "type": "object",
            "properties": {
                "day_name": {"type": "string"},
                "meal_date": {"type": "string", "description": "YYYY-MM-DD"},
                "slot": {"type": "string", "enum": ["breakfast", "lunch", "dinner", "snack"]},
                "recipe_name": {"type": "string"},
                "notes": {"type": "string"},
                "approved": {"type": "boolean"},
            },
            "required": ["day_name", "meal_date", "slot", "recipe_name"],
            "additionalProperties": False,
        },
        mutates_week=True,
        gated_action=None,
        runner=_run_add_meal,
    ),
    "swap_meal": AssistantTool(
        name="swap_meal",
        description="Replace a meal's recipe. Identify by meal_id, or (day_name + slot).",
        parameters_schema={
            "type": "object",
            "properties": {
                "meal_id": {"type": "string"},
                "day_name": {"type": "string"},
                "slot": {"type": "string"},
                "recipe_name": {"type": "string"},
                "notes": {"type": "string"},
            },
            "required": ["recipe_name"],
            "additionalProperties": False,
        },
        mutates_week=True,
        gated_action=None,
        runner=_run_swap_meal,
    ),
    "remove_meal": AssistantTool(
        name="remove_meal",
        description="Remove a meal. Identify by meal_id, or (day_name + slot).",
        parameters_schema={
            "type": "object",
            "properties": {
                "meal_id": {"type": "string"},
                "day_name": {"type": "string"},
                "slot": {"type": "string"},
            },
            "additionalProperties": False,
        },
        mutates_week=True,
        gated_action=None,
        runner=_run_remove_meal,
    ),
    "set_meal_approved": AssistantTool(
        name="set_meal_approved",
        description="Approve or unapprove a single meal.",
        parameters_schema={
            "type": "object",
            "properties": {
                "meal_id": {"type": "string"},
                "day_name": {"type": "string"},
                "slot": {"type": "string"},
                "approved": {"type": "boolean"},
            },
            "required": ["approved"],
            "additionalProperties": False,
        },
        mutates_week=True,
        gated_action=None,
        runner=_run_set_meal_approved,
    ),
    "rebalance_day": AssistantTool(
        name="rebalance_day",
        description=(
            "Regenerate a single day's meals to hit the dietary goal. Requires a "
            "dietary goal to be set. Pro tier (gated)."
        ),
        parameters_schema={
            "type": "object",
            "properties": {
                "meal_date": {"type": "string", "description": "YYYY-MM-DD"},
            },
            "required": ["meal_date"],
            "additionalProperties": False,
        },
        mutates_week=True,
        gated_action=ACTION_REBALANCE_DAY,
        runner=_run_rebalance_day,
    ),
    "fetch_pricing": AssistantTool(
        name="fetch_pricing",
        description="Fetch live Kroger prices for the week's grocery list. Week must be approved.",
        parameters_schema={
            "type": "object",
            "properties": {
                "location_id": {"type": "string", "description": "Kroger store locationId."},
            },
            "additionalProperties": False,
        },
        mutates_week=True,
        gated_action=ACTION_PRICING_FETCH,
        runner=_run_fetch_pricing,
    ),
    "set_dietary_goal": AssistantTool(
        name="set_dietary_goal",
        description="Set or update the user's dietary goal (calories + macro targets).",
        parameters_schema={
            "type": "object",
            "properties": {
                "goal_type": {"type": "string", "enum": ["lose", "maintain", "gain", "custom"]},
                "daily_calories": {"type": "integer"},
                "protein_g": {"type": "integer"},
                "carbs_g": {"type": "integer"},
                "fat_g": {"type": "integer"},
                "fiber_g": {"type": "integer"},
                "notes": {"type": "string"},
            },
            "required": ["goal_type", "daily_calories", "protein_g", "carbs_g", "fat_g"],
            "additionalProperties": False,
        },
        mutates_week=False,
        gated_action=None,
        runner=_run_set_dietary_goal,
    ),
}


def openai_tools_schema() -> list[dict[str, object]]:
    return [
        {
            "type": "function",
            "function": {
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters_schema,
            },
        }
        for tool in REGISTRY.values()
    ]


def anthropic_tools_schema() -> list[dict[str, object]]:
    return [
        {
            "name": tool.name,
            "description": tool.description,
            "input_schema": tool.parameters_schema,
        }
        for tool in REGISTRY.values()
    ]


def run_tool(
    name: str,
    *,
    session: Session,
    user_id: str,
    household_id: str,
    linked_week_id: str | None,
    args: dict[str, object],
    settings: Settings,
    on_event: Callable[[str, dict[str, object]], None] | None = None,
) -> AssistantToolResult:
    tool = REGISTRY.get(name)
    if tool is None:
        return AssistantToolResult(ok=False, detail=f"Unknown tool: {name}")

    week = _resolve_week(session, household_id, linked_week_id)

    if tool.gated_action is not None:
        try:
            ensure_action_allowed(session, user_id, tool.gated_action, settings=settings)
        except Exception as exc:  # UsageLimitReached from FastAPI HTTPException
            detail = getattr(exc, "detail", None)
            text = (
                detail.get("message") if isinstance(detail, dict) else str(detail or exc)
            )
            return AssistantToolResult(
                ok=False,
                detail=f"{text} (This is a Pro feature on the free tier.)",
            )

    runner_kwargs: dict[str, object] = {
        "session": session,
        "user_id": user_id,
        "household_id": household_id,
        "week": week,
        "args": dict(args or {}),
        "settings": settings,
    }
    # Only the tools that advertise support for incremental events accept
    # `on_event`. `generate_week_plan` is the only one today.
    if tool.runner is _run_generate_week_plan:
        runner_kwargs["on_event"] = on_event

    try:
        result = tool.runner(**runner_kwargs)
    except Exception as exc:
        logger.exception("Assistant tool %s crashed", name)
        return AssistantToolResult(ok=False, detail=f"Tool {name} crashed: {exc}")

    if result.ok and tool.gated_action is not None:
        increment_usage(session, user_id, tool.gated_action, settings=settings)

    return result
