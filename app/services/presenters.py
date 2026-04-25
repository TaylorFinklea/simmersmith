from __future__ import annotations

from collections import defaultdict
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.models import AssistantMessage, AssistantThread, DietaryGoal, ProfileSetting, Recipe, Staple, Week
from app.schemas import RecipePayload
from app.services.ai import secret_profile_flags, visible_profile_settings
from app.services.entitlements import all_usage_summaries, is_pro, is_trial_pro
from app.services.nutrition import MacroBreakdown, calculate_meal_macros, calculate_recipe_nutrition
from app.services.recipes import days_since, effective_override_fields, effective_recipe_data, family_last_used, source_counts


def dietary_goal_payload(goal: DietaryGoal | None) -> dict[str, object] | None:
    if goal is None:
        return None
    return {
        "goal_type": goal.goal_type,
        "daily_calories": goal.daily_calories,
        "protein_g": goal.protein_g,
        "carbs_g": goal.carbs_g,
        "fat_g": goal.fat_g,
        "fiber_g": goal.fiber_g,
        "notes": goal.notes,
        "updated_at": goal.updated_at,
    }


def profile_payload(session: Session, user_id: str) -> dict[str, object]:
    settings_records = session.scalars(
        select(ProfileSetting).where(ProfileSetting.user_id == user_id).order_by(ProfileSetting.key)
    ).all()
    staple_records = session.scalars(
        select(Staple).where(Staple.user_id == user_id).order_by(Staple.staple_name)
    ).all()
    dietary_goal = session.scalar(select(DietaryGoal).where(DietaryGoal.user_id == user_id))
    raw_settings = {setting.key: setting.value for setting in settings_records}
    settings = visible_profile_settings(raw_settings)
    staples = [
        {
            "staple_name": staple.staple_name,
            "normalized_name": staple.normalized_name,
            "notes": staple.notes,
            "is_active": staple.is_active,
        }
        for staple in staple_records
    ]
    timestamps = [setting.updated_at for setting in settings_records] + [staple.updated_at for staple in staple_records]
    if dietary_goal is not None:
        timestamps.append(dietary_goal.updated_at)
    usage = [summary.as_payload() for summary in all_usage_summaries(session, user_id)]
    return {
        "updated_at": max(timestamps) if timestamps else None,
        "settings": settings,
        "secret_flags": secret_profile_flags(raw_settings),
        "staples": staples,
        "dietary_goal": dietary_goal_payload(dietary_goal),
        "is_pro": is_pro(session, user_id),
        "is_trial": is_trial_pro(),
        "usage": usage,
    }


def recipe_payload(
    session: Session,
    recipe: Recipe,
    *,
    all_source_counts: dict[str, int] | None = None,
) -> dict[str, object]:
    data = effective_recipe_data(recipe)
    source_key = str(data.get("source_label") or data.get("source") or "manual").strip().lower()
    recipe_last_used = data.get("last_used")
    family_used = family_last_used(recipe)
    nutrition_summary = calculate_recipe_nutrition(session, data["ingredients"], data.get("servings"))
    return {
        "recipe_id": recipe.id,
        "recipe_template_id": recipe.recipe_template_id,
        "base_recipe_id": data["base_recipe_id"],
        "name": data["name"],
        "meal_type": data["meal_type"],
        "cuisine": data["cuisine"],
        "servings": data["servings"],
        "prep_minutes": data["prep_minutes"],
        "cook_minutes": data["cook_minutes"],
        "tags": data["tags"],
        "instructions_summary": data["instructions_summary"],
        "favorite": data["favorite"],
        "is_variant": recipe.base_recipe_id is not None,
        "override_fields": effective_override_fields(recipe),
        "variant_count": len(recipe.variants) if recipe.base_recipe_id is None else 0,
        "source_recipe_count": (all_source_counts or {}).get(source_key, 1),
        "family_last_used": family_used,
        "days_since_last_used": days_since(recipe_last_used),
        "family_days_since_last_used": days_since(family_used),
        "archived": recipe.archived,
        "source": data["source"],
        "source_label": data["source_label"],
        "source_url": data["source_url"],
        "notes": data["notes"],
        "memories": data["memories"],
        "last_used": recipe_last_used,
        "difficulty_score": recipe.difficulty_score,
        "kid_friendly": recipe.kid_friendly,
        "archived_at": recipe.archived_at,
        "updated_at": recipe.updated_at,
        "ingredients": data["ingredients"],
        "steps": data["steps"],
        "nutrition_summary": nutrition_summary.as_payload(),
    }


def recipes_payload(
    session: Session,
    user_id: str,
    include_archived: bool = False,
    cuisine: str = "",
    tags: list[str] | None = None,
) -> list[dict[str, object]]:
    statement = (
        select(Recipe)
        .where(Recipe.user_id == user_id)
        .options(
            selectinload(Recipe.ingredients),
            selectinload(Recipe.steps),
            selectinload(Recipe.base_recipe).selectinload(Recipe.ingredients),
            selectinload(Recipe.base_recipe).selectinload(Recipe.steps),
            selectinload(Recipe.variants).selectinload(Recipe.ingredients),
            selectinload(Recipe.variants).selectinload(Recipe.steps),
        )
        .order_by(Recipe.name)
    )
    if not include_archived:
        statement = statement.where(Recipe.archived.is_(False))
    recipes = session.scalars(statement).all()
    normalized_cuisine = cuisine.strip().lower()
    normalized_tags = {tag.strip().lower() for tag in (tags or []) if tag.strip()}
    if normalized_cuisine or normalized_tags:
        filtered_recipes: list[Recipe] = []
        for recipe in recipes:
            payload = effective_recipe_data(recipe)
            recipe_cuisine = str(payload.get("cuisine") or "").strip().lower()
            recipe_tags = {str(tag).strip().lower() for tag in payload.get("tags", []) if str(tag).strip()}
            if normalized_cuisine and recipe_cuisine != normalized_cuisine:
                continue
            if normalized_tags and not normalized_tags.issubset(recipe_tags):
                continue
            filtered_recipes.append(recipe)
        recipes = filtered_recipes
    counts = source_counts(recipes)
    return [recipe_payload(session, recipe, all_source_counts=counts) for recipe in recipes]


def week_payload(week: Week | None, *, session: Session | None = None) -> dict[str, object] | None:
    if week is None:
        return None

    meals = sorted(week.meals, key=lambda meal: (meal.meal_date, meal.sort_order, meal.slot))
    grocery_items = sorted(week.grocery_items, key=lambda item: (item.category, item.ingredient_name))

    meal_macros: dict[str, MacroBreakdown] = {}
    if session is not None:
        for meal in meals:
            # Scale by servings * scale_multiplier so the AI's "per-person"
            # plan lands near the user's daily target rather than the
            # recipe's full yield.
            ingredients = [
                {
                    "ingredient_name": ingredient.ingredient_name,
                    "normalized_name": ingredient.normalized_name,
                    "base_ingredient_id": ingredient.base_ingredient_id,
                    "ingredient_variation_id": ingredient.ingredient_variation_id,
                    "quantity": ingredient.quantity,
                    "unit": ingredient.unit,
                }
                for ingredient in meal.inline_ingredients
            ]
            raw = calculate_meal_macros(session, ingredients)
            scale = float(meal.scale_multiplier or 1.0)
            servings = float(meal.servings or 0.0)
            # Per-person macros: if the meal has servings, divide; otherwise
            # the raw total is already "per the household".
            factor = scale / servings if servings > 0 else scale
            meal_macros[meal.id] = raw.scaled(factor) if factor != 1.0 else raw

    daily_totals: dict[str, MacroBreakdown] = defaultdict(MacroBreakdown)
    for meal in meals:
        macros = meal_macros.get(meal.id)
        if macros is None or macros.is_empty:
            continue
        day_key = meal.meal_date.isoformat()
        daily_totals[day_key] = daily_totals[day_key] + macros

    nutrition_totals = [
        {"meal_date": day, **daily_totals[day].as_payload()}
        for day in sorted(daily_totals.keys())
    ]
    weekly_total = MacroBreakdown()
    for macros in daily_totals.values():
        weekly_total = weekly_total + macros

    return {
        "week_id": week.id,
        "week_start": week.week_start,
        "week_end": week.week_end,
        "status": week.status,
        "notes": week.notes,
        "ready_for_ai_at": week.ready_for_ai_at,
        "approved_at": week.approved_at,
        "priced_at": week.priced_at,
        "updated_at": week.updated_at,
        "staged_change_count": sum(len(batch.events) for batch in week.change_batches),
        "feedback_count": len(week.feedback_entries),
        "export_count": len(week.export_runs),
        "meals": [
            {
                "meal_id": meal.id,
                "day_name": meal.day_name,
                "meal_date": meal.meal_date,
                "slot": meal.slot,
                "recipe_id": meal.recipe_id,
        "recipe_name": meal.recipe_name,
        "servings": meal.servings,
        "scale_multiplier": meal.scale_multiplier,
        "source": meal.source,
                "approved": meal.approved,
                "notes": meal.notes,
                "ai_generated": meal.ai_generated,
                "updated_at": meal.updated_at,
                "macros": meal_macros[meal.id].as_payload() if meal.id in meal_macros and not meal_macros[meal.id].is_empty else None,
                "ingredients": [
                    {
                        "ingredient_id": ingredient.id,
                        "ingredient_name": ingredient.ingredient_name,
                        "normalized_name": ingredient.normalized_name,
                        "base_ingredient_id": ingredient.base_ingredient_id,
                        "base_ingredient_name": (
                            ingredient.base_ingredient.name if ingredient.base_ingredient is not None else None
                        ),
                        "ingredient_variation_id": ingredient.ingredient_variation_id,
                        "ingredient_variation_name": (
                            ingredient.ingredient_variation.name
                            if ingredient.ingredient_variation is not None
                            else None
                        ),
                        "resolution_status": ingredient.resolution_status,
                        "quantity": ingredient.quantity,
                        "unit": ingredient.unit,
                        "prep": ingredient.prep,
                        "category": ingredient.category,
                        "notes": ingredient.notes,
                    }
                    for ingredient in meal.inline_ingredients
                ],
            }
            for meal in meals
        ],
        "grocery_items": [
            {
                "grocery_item_id": item.id,
                "ingredient_name": item.ingredient_name,
                "normalized_name": item.normalized_name,
                "base_ingredient_id": item.base_ingredient_id,
                "base_ingredient_name": item.base_ingredient.name if item.base_ingredient is not None else None,
                "ingredient_variation_id": item.ingredient_variation_id,
                "ingredient_variation_name": (
                    item.ingredient_variation.name if item.ingredient_variation is not None else None
                ),
                "resolution_status": item.resolution_status,
                "total_quantity": item.total_quantity,
                "unit": item.unit,
                "quantity_text": item.quantity_text,
                "category": item.category,
                "source_meals": item.source_meals,
                "notes": item.notes,
                "review_flag": item.review_flag,
                "updated_at": item.updated_at,
                "retailer_prices": [
                    {
                        "retailer": price.retailer,
                        "status": price.status,
                        "store_name": price.store_name,
                        "product_name": price.product_name,
                        "package_size": price.package_size,
                        "unit_price": price.unit_price,
                        "line_price": price.line_price,
                        "product_url": price.product_url,
                        "availability": price.availability,
                        "candidate_score": price.candidate_score,
                        "review_note": price.review_note,
                        "raw_query": price.raw_query,
                        "scraped_at": price.scraped_at,
                    }
                    for price in sorted(item.retailer_prices, key=lambda entry: entry.retailer)
                ],
            }
            for item in grocery_items
        ],
        "nutrition_totals": nutrition_totals,
        "weekly_totals": weekly_total.as_payload() if not weekly_total.is_empty else None,
    }


def week_summary_payload(weeks: list[Week]) -> list[dict[str, object]]:
    return [
        {
            "week_id": week.id,
            "week_start": week.week_start,
            "week_end": week.week_end,
            "status": week.status,
            "notes": week.notes,
            "ready_for_ai_at": week.ready_for_ai_at,
            "approved_at": week.approved_at,
            "priced_at": week.priced_at,
            "updated_at": week.updated_at,
            "meal_count": len(week.meals),
            "grocery_item_count": len(week.grocery_items),
            "staged_change_count": sum(len(batch.events) for batch in week.change_batches),
            "feedback_count": len(week.feedback_entries),
            "export_count": len(week.export_runs),
        }
        for week in weeks
    ]


def pricing_payload(week: Week | None) -> dict[str, object] | None:
    if week is None:
        return None
    retailer_totals: dict[str, float] = defaultdict(float)
    for item in week.grocery_items:
        for price in item.retailer_prices:
            if price.line_price is not None:
                retailer_totals[price.retailer] += float(price.line_price)
    return {
        "week_id": week.id,
        "week_start": week.week_start,
        "totals": {key: round(value, 2) for key, value in sorted(retailer_totals.items())},
        "items": (week_payload(week, session=None) or {}).get("grocery_items", []),
    }


def assistant_message_payload(message: AssistantMessage) -> dict[str, Any]:
    import json as _json

    recipe_draft = None
    if (message.recipe_draft_json or "").strip():
        recipe_draft = RecipePayload.model_validate_json(message.recipe_draft_json).model_dump(mode="json")
    raw_tool_calls = (message.tool_calls_json or "").strip() or "[]"
    try:
        tool_calls = _json.loads(raw_tool_calls)
        if not isinstance(tool_calls, list):
            tool_calls = []
    except Exception:
        tool_calls = []
    return {
        "message_id": message.id,
        "thread_id": message.thread_id,
        "role": message.role,
        "status": message.status,
        "content_markdown": message.content_markdown,
        "recipe_draft": recipe_draft,
        "attached_recipe_id": message.attached_recipe_id,
        "tool_calls": tool_calls,
        "created_at": message.created_at,
        "completed_at": message.completed_at,
        "error": message.error,
    }


def assistant_thread_summary_payload(thread: AssistantThread) -> dict[str, Any]:
    return {
        "thread_id": thread.id,
        "title": thread.title,
        "preview": thread.preview,
        "thread_kind": thread.thread_kind,
        "linked_week_id": thread.linked_week_id,
        "created_at": thread.created_at,
        "updated_at": thread.updated_at,
    }


def assistant_thread_payload(thread: AssistantThread) -> dict[str, Any]:
    return {
        **assistant_thread_summary_payload(thread),
        "messages": [assistant_message_payload(message) for message in thread.messages],
    }
