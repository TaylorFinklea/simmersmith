from __future__ import annotations

from collections import defaultdict

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.models import ProfileSetting, Recipe, Staple, Week
from app.services.nutrition import calculate_recipe_nutrition
from app.services.recipes import days_since, effective_override_fields, effective_recipe_data, family_last_used, source_counts


def profile_payload(session: Session) -> dict[str, object]:
    settings_records = session.scalars(select(ProfileSetting).order_by(ProfileSetting.key)).all()
    staple_records = session.scalars(select(Staple).order_by(Staple.staple_name)).all()
    settings = {setting.key: setting.value for setting in settings_records}
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
    return {"updated_at": max(timestamps) if timestamps else None, "settings": settings, "staples": staples}


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
        "archived_at": recipe.archived_at,
        "updated_at": recipe.updated_at,
        "ingredients": data["ingredients"],
        "steps": data["steps"],
        "nutrition_summary": nutrition_summary.as_payload(),
    }


def recipes_payload(
    session: Session,
    include_archived: bool = False,
    cuisine: str = "",
    tags: list[str] | None = None,
) -> list[dict[str, object]]:
    recipes = session.scalars(
        select(Recipe)
        .options(
            selectinload(Recipe.ingredients),
            selectinload(Recipe.steps),
            selectinload(Recipe.base_recipe).selectinload(Recipe.ingredients),
            selectinload(Recipe.base_recipe).selectinload(Recipe.steps),
            selectinload(Recipe.variants).selectinload(Recipe.ingredients),
            selectinload(Recipe.variants).selectinload(Recipe.steps),
        )
        .where(True if include_archived else Recipe.archived.is_(False))
        .order_by(Recipe.name)
    ).all()
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


def week_payload(week: Week | None) -> dict[str, object] | None:
    if week is None:
        return None

    meals = sorted(week.meals, key=lambda meal: (meal.meal_date, meal.sort_order, meal.slot))
    grocery_items = sorted(week.grocery_items, key=lambda item: (item.category, item.ingredient_name))
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
                "ingredients": [
                    {
                        "ingredient_id": ingredient.id,
                        "ingredient_name": ingredient.ingredient_name,
                        "normalized_name": ingredient.normalized_name,
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
        "items": (week_payload(week) or {}).get("grocery_items", []),
    }
