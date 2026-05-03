"""Event grocery list generation + merge into the weekly list.

Mirrors app/services/grocery.py conceptually but scoped to EventMeals.
The merge helper takes an event's generated grocery rows and adds
their quantities onto the target week's existing GroceryItem rows
(by base_ingredient_id key). Traceability lives in
EventGroceryItem.merged_into_week_id + merged_into_grocery_item_id.
"""
from __future__ import annotations

import json
import logging
from collections import defaultdict
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import (
    Event,
    EventGroceryItem,
    EventMealIngredient,
    GroceryItem,
    Recipe,
    RecipeIngredient,
    Week,
)
from app.services.grocery import normalize_name, normalize_unit, staple_names
from app.services.ingredient_catalog import choice_for_base_ingredient

logger = logging.getLogger(__name__)


def _aggregate_event_rows(
    session: Session,
    *,
    user_id: str,
    event: Event,
) -> list[dict[str, Any]]:
    """Mirror of build_grocery_rows_for_week but driven by EventMeals."""
    meals = list(event.meals)
    meal_ids = [m.id for m in meals]
    recipe_ids = [m.recipe_id for m in meals if m.recipe_id]

    recipes = (
        {
            r.id: r
            for r in session.scalars(select(Recipe).where(Recipe.id.in_(recipe_ids))).all()
        }
        if recipe_ids
        else {}
    )
    ingredients_by_recipe: dict[str, list[RecipeIngredient]] = defaultdict(list)
    if recipe_ids:
        for ing in session.scalars(
            select(RecipeIngredient).where(RecipeIngredient.recipe_id.in_(recipe_ids))
        ).all():
            ingredients_by_recipe[ing.recipe_id].append(ing)

    inline_by_meal: dict[str, list[EventMealIngredient]] = defaultdict(list)
    if meal_ids:
        for ing in session.scalars(
            select(EventMealIngredient).where(EventMealIngredient.event_meal_id.in_(meal_ids))
        ).all():
            inline_by_meal[ing.event_meal_id].append(ing)

    staples = staple_names(session, user_id)
    aggregations: dict[tuple[str, str, str, str], dict[str, Any]] = {}

    for meal in meals:
        # Dishes assigned to a guest are being *brought* by that guest,
        # so their ingredients are not on the host's shopping list.
        # The meal itself stays visible on the event (with an assignee
        # chip) — just no grocery contribution.
        if meal.assigned_guest_id:
            continue
        recipe = recipes.get(meal.recipe_id or "")
        if recipe:
            base_servings = recipe.servings or 1.0
            meal_servings = meal.servings or base_servings
            factor = meal.scale_multiplier or (
                meal_servings / base_servings if base_servings else 1.0
            )
            ingredients: list[Any] = list(ingredients_by_recipe.get(recipe.id, []))
        else:
            factor = meal.scale_multiplier or 1.0
            ingredients = list(inline_by_meal.get(meal.id, []))

        for ing in ingredients:
            name = ing.ingredient_name.strip()
            if not name:
                continue
            normalized = normalize_name(ing.normalized_name or name)
            if normalized in staples:
                continue

            unit = normalize_unit(ing.unit)
            quantity = ing.quantity * factor if ing.quantity is not None else None
            quantity_text = "" if quantity is not None else str(getattr(ing, "quantity_text", "") or "")
            locked_variation = (
                ing.ingredient_variation_id
                if getattr(ing, "resolution_status", "") == "locked"
                else ""
            )
            base_key = getattr(ing, "base_ingredient_id", "") or normalized
            key = (base_key, locked_variation or "", unit, quantity_text)
            bucket = aggregations.get(key)
            if bucket is None:
                bucket = {
                    "ingredient_name": name,
                    "normalized_name": normalized,
                    "base_ingredient_id": getattr(ing, "base_ingredient_id", None),
                    "ingredient_variation_id": getattr(ing, "ingredient_variation_id", None),
                    "resolution_status": getattr(ing, "resolution_status", "unresolved"),
                    "total_quantity": 0.0 if quantity is not None else None,
                    "unit": unit,
                    "quantity_text": "",
                    "category": ing.category,
                    "source_meals": set(),
                    "notes": set(),
                    "review_flag": "",
                }
                aggregations[key] = bucket

            if quantity is not None:
                bucket["total_quantity"] = float(bucket["total_quantity"] or 0) + quantity
            elif quantity_text:
                bucket["quantity_text"] = quantity_text
                bucket["review_flag"] = "quantity review"

            if ing.notes:
                bucket["notes"].add(ing.notes)
            if ing.prep:
                bucket["notes"].add(ing.prep)
            if ing.category and not bucket["category"]:
                bucket["category"] = ing.category
            bucket["source_meals"].add(meal.id)

    rows: list[dict[str, Any]] = []
    for bucket in aggregations.values():
        base, chosen_variation, chosen_status = choice_for_base_ingredient(
            session,
            user_id=user_id,
            base_ingredient_id=bucket.get("base_ingredient_id"),
            recipe_variation_id=bucket.get("ingredient_variation_id"),
            recipe_resolution_status=str(bucket.get("resolution_status") or "unresolved"),
        )
        display_name = (
            chosen_variation.name
            if chosen_variation is not None
            else base.name
            if base is not None
            else bucket["ingredient_name"]
        )
        normalized = (
            chosen_variation.normalized_name
            if chosen_variation is not None
            else base.normalized_name
            if base is not None
            else bucket["normalized_name"]
        )
        total = bucket["total_quantity"]
        if isinstance(total, float):
            total = round(total, 2)
        review = bucket["review_flag"]
        if base is None:
            review = review or "ingredient review"

        rows.append(
            {
                "ingredient_name": display_name,
                "normalized_name": normalized,
                "base_ingredient_id": base.id if base is not None else None,
                "ingredient_variation_id": chosen_variation.id if chosen_variation is not None else None,
                "resolution_status": chosen_status,
                "total_quantity": total,
                "unit": bucket["unit"],
                "quantity_text": bucket["quantity_text"],
                "category": bucket["category"],
                "source_meals": json.dumps(sorted(bucket["source_meals"])),
                "notes": "; ".join(sorted(bucket["notes"])),
                "review_flag": review,
            }
        )
    rows.sort(key=lambda r: ((r.get("category") or "").lower(), r["ingredient_name"].lower()))
    return rows


def regenerate_event_grocery(session: Session, user_id: str, event: Event) -> list[EventGroceryItem]:
    """Wipe + rebuild an event's grocery list from its current meals."""
    session.execute(
        delete(EventGroceryItem).where(EventGroceryItem.event_id == event.id)
    )
    session.flush()

    rows = _aggregate_event_rows(session, user_id=user_id, event=event)
    created: list[EventGroceryItem] = []
    for row in rows:
        item = EventGroceryItem(
            event_id=event.id,
            base_ingredient_id=row["base_ingredient_id"],
            ingredient_variation_id=row["ingredient_variation_id"],
            ingredient_name=row["ingredient_name"],
            normalized_name=row["normalized_name"],
            total_quantity=row["total_quantity"],
            unit=row["unit"],
            quantity_text=row["quantity_text"],
            category=row["category"],
            source_meals=row["source_meals"],
            notes=row["notes"],
            review_flag=row["review_flag"],
            resolution_status=row["resolution_status"],
        )
        session.add(item)
        created.append(item)
    session.flush()
    # The bulk delete bypassed the ORM session's identity map for the
    # `grocery_items` collection, so callers iterating `event.grocery_items`
    # right after this would see the stale (deleted) rows. Expire the
    # collection so the next access re-queries the freshly inserted set.
    session.expire(event, ["grocery_items"])
    return created


def _match_keys(row: Any) -> tuple[tuple[str, str, str], tuple[str, str, str]]:
    """Pair of stable keys used to match an event grocery row with a
    weekly grocery row.

    Returns `(base_key, name_key)`:
    - `base_key` includes `base_ingredient_id` when the row has one
      (catalog-resolved match wins when both sides have IDs).
    - `name_key` falls back to the `normalized_name` so a row that
      didn't resolve to a catalog entry can still match its
      counterpart by name + unit. M22.2 needs this because event
      meal ingredients often skip catalog resolution while the
      week's recipe-derived rows resolve through `choice_for_base_ingredient`.

    Both keys carry the normalized unit so 2 lb chicken doesn't merge
    with 1 oz chicken.
    """
    base = getattr(row, "base_ingredient_id", None) or ""
    norm = getattr(row, "normalized_name", "") or ""
    unit = normalize_unit(getattr(row, "unit", "") or "")
    base_key = (base, unit, "") if base else ("", unit, norm)
    name_key = (norm, unit, "")
    return (base_key, name_key)


def merge_event_into_week(
    session: Session,
    *,
    user_id: str,
    event: Event,
    week: Week,
) -> dict[str, int]:
    """Add each event grocery row's total_quantity to the matching row on
    the week's grocery list. When no match exists, a new GroceryItem is
    created on the week and attributed to the event. Returns a small
    counts dict: {matched, created, unmatched_text_only}.

    Idempotent up to previously-merged rows — an event row that already
    points to a grocery_item_id on this week is skipped so callers can
    re-run safely.
    """
    # Index weekly rows by both base-id and normalized-name keys so a
    # catalog-resolved week row still matches a name-only event row
    # (and vice versa).
    week_rows = list(session.scalars(select(GroceryItem).where(GroceryItem.week_id == week.id)).all())
    week_index: dict[tuple[str, str, str], GroceryItem] = {}
    for row in week_rows:
        base_key, name_key = _match_keys(row)
        if base_key not in week_index:
            week_index[base_key] = row
        if name_key not in week_index:
            week_index[name_key] = row

    counts = {"matched": 0, "created": 0, "unmatched_text_only": 0}
    for ev_row in list(event.grocery_items):
        # Skip already-merged rows (idempotency)
        if ev_row.merged_into_week_id == week.id and ev_row.merged_into_grocery_item_id:
            continue
        if ev_row.total_quantity is None:
            # Quantity-text only (e.g. "to taste") — we don't currently
            # combine these because the semantics are ambiguous. Mark
            # as merged for traceability but skip the numeric add.
            counts["unmatched_text_only"] += 1
            ev_row.merged_into_week_id = week.id
            continue

        ev_base_key, ev_name_key = _match_keys(ev_row)
        match = week_index.get(ev_base_key) or week_index.get(ev_name_key)
        if match is not None:
            # M22.2: event contribution is tracked separately so smart
            # merge can refresh the week-meal portion without
            # disturbing it. Display sums the two.
            match.event_quantity = round(
                (match.event_quantity or 0.0) + (ev_row.total_quantity or 0.0), 2
            )
            ev_row.merged_into_week_id = week.id
            ev_row.merged_into_grocery_item_id = match.id
            counts["matched"] += 1
        else:
            # Create a new event-only GroceryItem on the week — no
            # week-meal contribution, just event_quantity. Smart merge
            # leaves it untouched (recognized via event_quantity > 0).
            new_row = GroceryItem(
                week_id=week.id,
                base_ingredient_id=ev_row.base_ingredient_id,
                ingredient_variation_id=ev_row.ingredient_variation_id,
                ingredient_name=ev_row.ingredient_name,
                normalized_name=ev_row.normalized_name,
                total_quantity=None,
                event_quantity=ev_row.total_quantity,
                unit=ev_row.unit,
                quantity_text=ev_row.quantity_text,
                category=ev_row.category,
                source_meals=f"event:{event.name}",
                notes=ev_row.notes,
                review_flag=ev_row.review_flag,
                resolution_status=ev_row.resolution_status,
            )
            session.add(new_row)
            session.flush()
            ev_row.merged_into_week_id = week.id
            ev_row.merged_into_grocery_item_id = new_row.id
            # Index so further event rows in the same call dedupe.
            new_base_key, new_name_key = _match_keys(new_row)
            week_index[new_base_key] = new_row
            week_index[new_name_key] = new_row
            counts["created"] += 1

    event.linked_week_id = week.id
    return counts


def _resolve_target_week(session: Session, event: Event, household_id: str) -> Week | None:
    """Find the week the event should auto-merge into. Prefer an
    explicit `linked_week_id`; otherwise look up the household's week
    whose `[week_start, week_end]` range contains `event.event_date`.
    Returns None when the event has no date or no week covers it.
    """
    if event.linked_week_id:
        return session.scalar(
            select(Week).where(
                Week.id == event.linked_week_id,
                Week.household_id == household_id,
            )
        )
    if event.event_date is None:
        return None
    return session.scalar(
        select(Week).where(
            Week.household_id == household_id,
            Week.week_start <= event.event_date,
            Week.week_end >= event.event_date,
        )
    )


def apply_auto_merge_policy(
    session: Session,
    *,
    event: Event,
    user_id: str,
    household_id: str,
) -> None:
    """Reconcile `event.auto_merge_grocery` with the event's actual merge
    state. Call this after any mutation that touches event meals OR
    flips the toggle itself.

    When True: idempotently merge the event's grocery rows into the
    week covering `event.event_date` (or `linked_week_id`).
    When False: if the event was previously merged into a week,
    unmerge from that week.
    """
    if event.auto_merge_grocery:
        target = _resolve_target_week(session, event, household_id)
        if target is not None:
            merge_event_into_week(session, user_id=user_id, event=event, week=target)
        return

    if event.linked_week_id is None:
        return
    week = session.scalar(
        select(Week).where(
            Week.id == event.linked_week_id,
            Week.household_id == household_id,
        )
    )
    if week is not None:
        unmerge_event_from_week(session, event=event, week=week)


def unmerge_event_from_week(session: Session, *, event: Event, week: Week) -> int:
    """Reverse a prior merge. Subtracts each event grocery row's
    contribution from the matching weekly row's `event_quantity`. If
    the row was event-only (no week-meal contribution) and its
    `event_quantity` goes to zero with no user investment, delete it.
    Returns how many rows were touched.
    """
    touched = 0
    for ev_row in list(event.grocery_items):
        if ev_row.merged_into_week_id != week.id:
            continue
        target = ev_row.merged_into_grocery_item
        if target is not None and ev_row.total_quantity is not None:
            current_event_qty = target.event_quantity or 0.0
            new_event_qty = round(current_event_qty - ev_row.total_quantity, 2)
            target.event_quantity = new_event_qty if new_event_qty > 0.0001 else None
            # Strip any legacy "+event: X" notes from pre-M22.2 merges
            # so the display doesn't show stale attribution.
            if target.notes:
                target.notes = "; ".join(
                    part for part in (target.notes or "").split("; ")
                    if part and f"+event: {event.name}" not in part
                )
            # Event-only rows (created by the merge) self-delete when
            # their event contribution is gone and the user hasn't
            # invested in them. We detect "event-only" by the
            # `source_meals == "event:<name>"` marker the merge code
            # writes when creating a fresh row.
            event_only = (target.source_meals or "").startswith(f"event:{event.name}")
            no_remaining_qty = (target.total_quantity or 0) <= 0 and (target.event_quantity or 0) <= 0
            no_user_investment = (
                target.quantity_override is None
                and target.unit_override is None
                and target.notes_override is None
                and not target.is_checked
                and not target.is_user_added
            )
            if event_only and no_remaining_qty and no_user_investment:
                session.delete(target)
        ev_row.merged_into_week_id = None
        ev_row.merged_into_grocery_item_id = None
        touched += 1
    if event.linked_week_id == week.id:
        event.linked_week_id = None
    return touched
