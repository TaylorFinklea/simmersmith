from __future__ import annotations

import json
import re

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import (
    AIRun,
    ProfileSetting,
    Recipe,
    RecipeIngredient,
    RecipeStep,
    Week,
    WeekChangeBatch,
    WeekMeal,
    WeekMealIngredient,
    utcnow,
)
from app.schemas import DraftFromAIRequest, MealUpdatePayload, RecipePayload
from app.services.change_history import ai_baseline_changes, build_change_event, record_change_batch
from app.services.grocery import normalize_name, regenerate_grocery_for_week
from app.services.managed_lists import sync_items
from app.services.recipe_templates import default_template, get_template
from app.services.recipes import (
    RECIPE_OVERRIDE_FIELDS,
    effective_recipe_data,
    mark_week_recipe_usage,
    normalize_tag_list,
    serialize_tag_list,
    split_summary_into_steps,
)
from app.services.weeks import finalize_week, invalidate_week, mark_week_ready_for_ai, slot_sort


def slugify(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return normalized or "recipe"


def upsert_profile_settings(session: Session, updates: dict[str, str]) -> None:
    for key, value in updates.items():
        setting = session.get(ProfileSetting, key)
        if setting is None:
            setting = ProfileSetting(key=key, value=value, updated_at=utcnow())
            session.add(setting)
        else:
            setting.value = value
            setting.updated_at = utcnow()
    session.flush()


def normalized_step_payloads(payload: RecipePayload) -> list[dict[str, object]]:
    if payload.steps:
        step_payloads: list[dict[str, object]] = []
        for index, step in enumerate(payload.steps, start=1):
            instruction = step.instruction.strip()
            if not instruction:
                continue
            substeps = [
                {
                    "step_id": substep.step_id,
                    "sort_order": substep.sort_order or sub_index,
                    "instruction": substep.instruction.strip(),
                    "substeps": [],
                }
                for sub_index, substep in enumerate(step.substeps, start=1)
                if substep.instruction.strip()
            ]
            step_payloads.append(
                {
                    "step_id": step.step_id,
                    "sort_order": step.sort_order or index,
                    "instruction": instruction,
                    "substeps": substeps,
                }
            )
        return step_payloads
    if payload.instructions_summary.strip():
        return [
            {
                "step_id": None,
                "sort_order": index,
                "instruction": instruction,
                "substeps": [],
            }
            for index, instruction in enumerate(split_summary_into_steps(payload.instructions_summary), start=1)
        ]
    return []


def summarized_steps(step_payloads: list[dict[str, object]]) -> str:
    if not step_payloads:
        return ""
    lines: list[str] = []
    for index, step_payload in enumerate(step_payloads, start=1):
        lines.append(f"{index}. {step_payload['instruction']}")
        for sub_index, substep in enumerate(step_payload.get("substeps", []), start=1):
            lines.append(f"   {chr(ord('a') + sub_index - 1)}. {substep['instruction']}")
    return "\n".join(lines)


def ingredient_payloads(payload: RecipePayload, session: Session | None = None) -> list[dict[str, object]]:
    normalized_ingredients = [
        {
            "ingredient_id": ingredient.ingredient_id,
            "ingredient_name": ingredient.ingredient_name,
            "normalized_name": ingredient.normalized_name or normalize_name(ingredient.ingredient_name),
            "quantity": ingredient.quantity,
            "unit": ingredient.unit,
            "prep": ingredient.prep,
            "category": ingredient.category,
            "notes": ingredient.notes,
        }
        for ingredient in payload.ingredients
        if ingredient.ingredient_name.strip()
    ]
    if session is not None:
        for ingredient in normalized_ingredients:
            unit = str(ingredient["unit"]).strip()
            if not unit:
                continue
            canonical_units = sync_items(session, "unit", [unit])
            if canonical_units:
                ingredient["unit"] = canonical_units[0]
    return normalized_ingredients


def flattened_step_records(
    recipe_id: str,
    step_payloads: list[dict[str, object]],
) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for index, step_payload in enumerate(step_payloads, start=1):
        step_id = str(step_payload.get("step_id") or f"{recipe_id}-step-{index}")
        records.append(
            {
                "step_id": step_id,
                "parent_step_id": None,
                "sort_order": int(step_payload.get("sort_order") or index),
                "instruction": str(step_payload["instruction"]),
            }
        )
        for sub_index, substep in enumerate(step_payload.get("substeps", []), start=1):
            substep_id = str(substep.get("step_id") or f"{step_id}-substep-{sub_index}")
            records.append(
                {
                    "step_id": substep_id,
                    "parent_step_id": step_id,
                    "sort_order": int(substep.get("sort_order") or sub_index),
                    "instruction": str(substep["instruction"]),
                }
            )
    return records


def variant_override_payload(base_recipe: Recipe, payload: RecipePayload) -> dict[str, object]:
    base_data = effective_recipe_data(base_recipe)
    current_steps = normalized_step_payloads(payload)
    overrides: dict[str, object] = {}
    candidate_values = {
        "recipe_template_id": payload.recipe_template_id or base_recipe.recipe_template_id,
        "meal_type": payload.meal_type,
        "cuisine": payload.cuisine,
        "servings": payload.servings,
        "prep_minutes": payload.prep_minutes,
        "cook_minutes": payload.cook_minutes,
        "tags": normalize_tag_list(payload.tags),
        "instructions_summary": payload.instructions_summary.strip() or summarized_steps(current_steps),
        "favorite": payload.favorite,
        "source": payload.source,
        "source_label": payload.source_label,
        "source_url": payload.source_url,
        "notes": payload.notes,
        "memories": payload.memories,
        "ingredients": ingredient_payloads(payload),
        "steps": current_steps,
    }
    for field_name in RECIPE_OVERRIDE_FIELDS:
        if candidate_values[field_name] != base_data.get(field_name):
            overrides[field_name] = candidate_values[field_name]
    return overrides


def upsert_recipe(session: Session, payload: RecipePayload) -> Recipe:
    recipe_id = payload.recipe_id or slugify(payload.name)
    recipe = session.get(Recipe, recipe_id)
    if recipe is None:
        recipe = Recipe(id=recipe_id, name=payload.name)
        session.add(recipe)

    base_recipe = None
    if payload.base_recipe_id:
        base_recipe = session.get(Recipe, payload.base_recipe_id)
        if base_recipe is None:
            raise ValueError("Base recipe not found")
        while base_recipe.base_recipe is not None:
            base_recipe = base_recipe.base_recipe

    step_payloads = normalized_step_payloads(payload)
    instructions_summary = payload.instructions_summary.strip() or summarized_steps(step_payloads)
    cuisine = payload.cuisine.strip()
    canonical_cuisine = sync_items(session, "cuisine", [cuisine]) if cuisine else []
    cuisine = canonical_cuisine[0] if canonical_cuisine else ""
    tags = sync_items(session, "tag", normalize_tag_list(payload.tags))
    recipe_template = None
    requested_template_id = payload.recipe_template_id or recipe.recipe_template_id
    if requested_template_id:
        recipe_template = get_template(session, requested_template_id)
        if recipe_template is None:
            raise ValueError("Recipe template not found")
    else:
        recipe_template = default_template(session)

    recipe.recipe_template_id = recipe_template.id if recipe_template is not None else None
    recipe.base_recipe_id = base_recipe.id if base_recipe is not None else None
    recipe.name = payload.name
    recipe.meal_type = payload.meal_type
    recipe.cuisine = cuisine
    recipe.servings = payload.servings
    recipe.prep_minutes = payload.prep_minutes
    recipe.cook_minutes = payload.cook_minutes
    recipe.tags = serialize_tag_list(tags)
    recipe.instructions_summary = instructions_summary
    recipe.favorite = payload.favorite
    recipe.archived = False
    recipe.archived_at = None
    recipe.source = payload.source
    recipe.source_label = payload.source_label
    recipe.source_url = payload.source_url
    recipe.notes = payload.notes
    recipe.memories = payload.memories
    recipe.last_used = payload.last_used
    recipe.override_payload_json = (
        json.dumps(variant_override_payload(base_recipe, payload), sort_keys=True)
        if base_recipe is not None
        else "{}"
    )
    session.flush()

    session.execute(delete(RecipeIngredient).where(RecipeIngredient.recipe_id == recipe.id))
    session.execute(delete(RecipeStep).where(RecipeStep.recipe_id == recipe.id))
    for index, ingredient in enumerate(ingredient_payloads(payload, session), start=1):
        ingredient_id = ingredient["ingredient_id"] or f"{recipe.id}-ingredient-{index}"
        session.add(
            RecipeIngredient(
                id=ingredient_id,
                recipe_id=recipe.id,
                ingredient_name=str(ingredient["ingredient_name"]),
                normalized_name=str(ingredient["normalized_name"]),
                quantity=ingredient["quantity"],
                unit=str(ingredient["unit"]),
                prep=str(ingredient["prep"]),
                category=str(ingredient["category"]),
                notes=str(ingredient["notes"]),
            )
        )
    for step_record in flattened_step_records(recipe.id, step_payloads):
        session.add(
            RecipeStep(
                id=str(step_record["step_id"]),
                recipe_id=recipe.id,
                parent_step_id=step_record["parent_step_id"],
                sort_order=int(step_record["sort_order"]),
                instruction=str(step_record["instruction"]),
            )
        )
    session.flush()
    return recipe


def inline_ingredient_id(meal_id: str, index: int) -> str:
    return f"{meal_id}-ingredient-{index}"


def default_approved_for_slot(slot: str, requested: bool) -> bool:
    return True if slot.lower() == "snack" else requested


def apply_ai_draft(session: Session, week: Week, payload: DraftFromAIRequest) -> Week:
    if payload.profile_updates:
        upsert_profile_settings(session, payload.profile_updates)

    known_recipes: dict[str, Recipe] = {}
    for recipe_payload in payload.recipes:
        recipe = upsert_recipe(session, recipe_payload)
        known_recipes[recipe.id] = recipe

    session.execute(delete(WeekMeal).where(WeekMeal.week_id == week.id))
    session.execute(delete(WeekChangeBatch).where(WeekChangeBatch.week_id == week.id))
    session.flush()

    for meal in payload.meal_plan:
        recipe_id = meal.recipe_id
        if recipe_id and recipe_id not in known_recipes:
            recipe = session.get(Recipe, recipe_id)
            if recipe is not None:
                known_recipes[recipe_id] = recipe

        week_meal = WeekMeal(
            week_id=week.id,
            day_name=meal.day_name,
            meal_date=meal.meal_date,
            slot=meal.slot,
            recipe_id=recipe_id,
            recipe_name=meal.recipe_name,
            servings=meal.servings,
            scale_multiplier=1.0,
            source=meal.source,
            approved=default_approved_for_slot(meal.slot, meal.approved),
            notes=meal.notes,
            ai_generated=True,
            sort_order=slot_sort(meal.slot),
        )
        session.add(week_meal)
        session.flush()

        for index, ingredient in enumerate(meal.ingredients, start=1):
            session.add(
                WeekMealIngredient(
                    id=inline_ingredient_id(week_meal.id, index),
                    week_meal_id=week_meal.id,
                    ingredient_name=ingredient.ingredient_name,
                    normalized_name=ingredient.normalized_name or normalize_name(ingredient.ingredient_name),
                    quantity=ingredient.quantity,
                    unit=ingredient.unit,
                    prep=ingredient.prep,
                    category=ingredient.category,
                    notes=ingredient.notes,
                )
            )

    session.flush()
    week.status = "staging"
    week.notes = payload.week_notes or week.notes
    week.ready_for_ai_at = None
    week.approved_at = None
    week.priced_at = None
    week.updated_at = utcnow()

    ai_run = AIRun(
        week_id=week.id,
        run_type="draft",
        model=payload.model,
        prompt=payload.prompt,
        status="completed",
        request_payload=payload.model_dump_json(),
        response_payload=json.dumps(
            {
                "recipe_count": len(payload.recipes),
                "meal_count": len(payload.meal_plan),
            }
        ),
        completed_at=utcnow(),
    )
    session.add(ai_run)
    session.flush()

    regenerate_grocery_for_week(session, week)
    session.flush()
    baseline_meals = list(
        session.scalars(select(WeekMeal).where(WeekMeal.week_id == week.id).order_by(WeekMeal.meal_date, WeekMeal.sort_order))
    )
    record_change_batch(
        session,
        week,
        actor_type="agent_chat",
        actor_label=payload.model,
        summary="Applied AI draft baseline.",
        changes=ai_baseline_changes(baseline_meals),
    )
    return week


def update_week_meals(session: Session, week: Week, updates: list[MealUpdatePayload]) -> Week:
    lookup = {meal.id: meal for meal in week.meals}
    slot_lookup = {(meal.day_name, meal.slot): meal for meal in week.meals}
    changed = False
    changed_meal_ids: set[str] = set()
    kept_meal_ids: set[str] = set()
    created_count = 0
    removed_count = 0
    changes: list[dict[str, str]] = []
    previous_status = week.status
    for update in updates:
        if not update.recipe_name.strip():
            continue
        meal = lookup.get(update.meal_id) if update.meal_id else None
        if meal is None:
            meal = slot_lookup.get((update.day_name, update.slot))
        if meal is None:
            approved_value = default_approved_for_slot(update.slot, update.approved)
            meal = WeekMeal(
                week_id=week.id,
                day_name=update.day_name,
                meal_date=update.meal_date,
                slot=update.slot,
                recipe_id=update.recipe_id,
                recipe_name=update.recipe_name,
                servings=update.servings,
                scale_multiplier=update.scale_multiplier,
                source="user",
                approved=approved_value,
                notes=update.notes,
                ai_generated=False,
                sort_order=slot_sort(update.slot),
            )
            session.add(meal)
            session.flush()
            lookup[meal.id] = meal
            slot_lookup[(meal.day_name, meal.slot)] = meal
            kept_meal_ids.add(meal.id)
            changed_meal_ids.add(meal.id)
            changed = True
            created_count += 1
            for field_name, after_value in [
                ("recipe_name", update.recipe_name),
                ("recipe_id", update.recipe_id),
                ("servings", update.servings),
                ("scale_multiplier", update.scale_multiplier),
                ("notes", update.notes),
                ("approved", approved_value),
            ]:
                changes.append(
                    build_change_event(
                        entity_type="meal",
                        entity_id=meal.id,
                        field_name=field_name,
                        before_value="",
                        after_value=after_value,
                    )
                )
            continue

        kept_meal_ids.add(meal.id)
        meal_changes: list[tuple[str, object, object]] = []
        approved_value = default_approved_for_slot(meal.slot, update.approved)
        if meal.day_name != update.day_name:
            meal_changes.append(("day_name", meal.day_name, update.day_name))
        if meal.meal_date != update.meal_date:
            meal_changes.append(("meal_date", meal.meal_date, update.meal_date))
        if meal.slot != update.slot:
            meal_changes.append(("slot", meal.slot, update.slot))
        if meal.recipe_id != update.recipe_id:
            meal_changes.append(("recipe_id", meal.recipe_id, update.recipe_id))
        if meal.recipe_name != update.recipe_name:
            meal_changes.append(("recipe_name", meal.recipe_name, update.recipe_name))
        if meal.servings != update.servings:
            meal_changes.append(("servings", meal.servings, update.servings))
        if meal.scale_multiplier != update.scale_multiplier:
            meal_changes.append(("scale_multiplier", meal.scale_multiplier, update.scale_multiplier))
        if meal.notes != update.notes:
            meal_changes.append(("notes", meal.notes, update.notes))
        if meal.approved != approved_value:
            meal_changes.append(("approved", meal.approved, approved_value))
        if meal_changes:
            changed = True
            changed_meal_ids.add(meal.id)
            for field_name, before_value, after_value in meal_changes:
                changes.append(
                    build_change_event(
                        entity_type="meal",
                        entity_id=meal.id,
                        field_name=field_name,
                        before_value=before_value,
                        after_value=after_value,
                    )
                )
            meal.day_name = update.day_name
            meal.meal_date = update.meal_date
            meal.slot = update.slot
            meal.sort_order = slot_sort(update.slot)
            meal.source = "user"
            meal.ai_generated = False
        meal.recipe_id = update.recipe_id
        meal.recipe_name = update.recipe_name
        meal.servings = update.servings
        meal.scale_multiplier = update.scale_multiplier
        meal.notes = update.notes
        meal.approved = approved_value

    for meal in list(week.meals):
        if meal.id in kept_meal_ids:
            continue
        changed = True
        removed_count += 1
        changed_meal_ids.add(meal.id)
        changes.append(
            build_change_event(
                entity_type="meal",
                entity_id=meal.id,
                field_name="recipe_name",
                before_value=meal.recipe_name,
                after_value="",
            )
        )
        session.delete(meal)

    if changed:
        invalidate_week(session, week)
        if previous_status != week.status:
            changes.append(
                build_change_event(
                    entity_type="week",
                    entity_id=week.id,
                    field_name="status",
                    before_value=previous_status,
                    after_value=week.status,
                )
            )
        record_change_batch(
            session,
            week,
            actor_type="user_ui",
            actor_label="Week workspace",
            summary=(
                f"Planned {created_count} new, updated {max(len(changed_meal_ids) - created_count - removed_count, 0)}, "
                f"removed {removed_count} meal{'s' if removed_count != 1 else ''}."
            ),
            changes=changes,
        )
        regenerate_grocery_for_week(session, week)
    else:
        week.updated_at = utcnow()
    session.flush()
    return week


def set_week_ready_for_ai(session: Session, week: Week) -> Week:
    previous_status = week.status
    mark_week_ready_for_ai(week)
    record_change_batch(
        session,
        week,
        actor_type="user_ui",
        actor_label="Week workspace",
        summary="Marked week ready for chat finalization.",
        changes=[
            build_change_event(
                entity_type="week",
                entity_id=week.id,
                field_name="status",
                before_value=previous_status,
                after_value=week.status,
            )
        ],
    )
    session.flush()
    return week


def set_week_approved(session: Session, week: Week) -> Week:
    previous_status = week.status
    finalize_week(week)
    mark_week_recipe_usage(session, week)
    record_change_batch(
        session,
        week,
        actor_type="agent_chat",
        actor_label="Chat finalization",
        summary="Approved finalized week.",
        changes=[
            build_change_event(
                entity_type="week",
                entity_id=week.id,
                field_name="status",
                before_value=previous_status,
                after_value=week.status,
            )
        ],
    )
    session.flush()
    return week
