"""Event Plans service layer — guest + event CRUD and helpers shared
across the REST endpoints, AI generation (Phase 2), and the grocery
merge (Phase 3).
"""
from __future__ import annotations

import json
from datetime import date
from typing import Iterable

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.models import (
    Event,
    EventAttendee,
    EventMeal,
    EventMealIngredient,
    Guest,
)
from app.models._base import new_id


# ---------------------------------------------------------------------
# Guest CRUD
# ---------------------------------------------------------------------

def list_guests(session: Session, household_id: str, *, include_inactive: bool = False) -> list[Guest]:
    stmt = select(Guest).where(Guest.household_id == household_id).order_by(Guest.name)
    if not include_inactive:
        stmt = stmt.where(Guest.active.is_(True))
    return list(session.scalars(stmt).all())


def get_guest(session: Session, household_id: str, guest_id: str) -> Guest | None:
    return session.scalar(
        select(Guest).where(Guest.id == guest_id, Guest.household_id == household_id)
    )


VALID_AGE_GROUPS = {"baby", "toddler", "child", "teen", "adult"}


def upsert_guest(
    session: Session,
    user_id: str,
    household_id: str,
    *,
    guest_id: str | None,
    name: str,
    relationship_label: str = "",
    dietary_notes: str = "",
    allergies: str = "",
    age_group: str = "adult",
    active: bool = True,
) -> Guest:
    if age_group not in VALID_AGE_GROUPS:
        raise ValueError(f"age_group must be one of: {sorted(VALID_AGE_GROUPS)}")
    guest: Guest | None = None
    if guest_id:
        guest = get_guest(session, household_id, guest_id)
        if guest is None:
            raise ValueError("Guest not found")
    if guest is None:
        guest = Guest(user_id=user_id, household_id=household_id, name=name)
        session.add(guest)
    guest.name = name.strip()
    guest.relationship_label = relationship_label.strip()
    guest.dietary_notes = dietary_notes.strip()
    guest.allergies = allergies.strip()
    guest.age_group = age_group
    guest.active = active
    session.flush()
    return guest


def delete_guest(session: Session, household_id: str, guest_id: str) -> bool:
    guest = get_guest(session, household_id, guest_id)
    if guest is None:
        return False
    session.delete(guest)
    return True


# ---------------------------------------------------------------------
# Event CRUD
# ---------------------------------------------------------------------

def list_events(session: Session, household_id: str) -> list[Event]:
    stmt = (
        select(Event)
        .where(Event.household_id == household_id)
        .order_by(Event.event_date.is_(None), Event.event_date, Event.created_at.desc())
        .options(selectinload(Event.meals), selectinload(Event.attendees))
    )
    return list(session.scalars(stmt).all())


def get_event(session: Session, household_id: str, event_id: str) -> Event | None:
    from app.models import EventPantrySupplement

    return session.scalar(
        select(Event)
        .where(Event.id == event_id, Event.household_id == household_id)
        .options(
            selectinload(Event.attendees).selectinload(EventAttendee.guest),
            selectinload(Event.meals).selectinload(EventMeal.inline_ingredients),
            selectinload(Event.grocery_items),
            selectinload(Event.pantry_supplements).selectinload(EventPantrySupplement.pantry_item),
        )
    )


def create_event(
    session: Session,
    user_id: str,
    household_id: str,
    *,
    name: str,
    event_date: date | None,
    occasion: str,
    attendee_count: int,
    notes: str,
    attendees: Iterable[tuple[str, int]] = (),
) -> Event:
    event = Event(
        user_id=user_id,
        household_id=household_id,
        name=name.strip() or "Untitled event",
        event_date=event_date,
        occasion=occasion.strip() or "other",
        attendee_count=max(0, int(attendee_count)),
        notes=notes,
    )
    session.add(event)
    session.flush()
    _sync_attendees(session, event, attendees, household_id=household_id)
    return event


_UNSET: object = object()


def update_event(
    session: Session,
    event: Event,
    *,
    name: str | None,
    event_date: date | None,
    occasion: str | None,
    attendee_count: int | None,
    notes: str | None,
    status: str | None,
    attendees: list[tuple[str, int]] | None = None,
    household_id: str,
    auto_merge_grocery: object = _UNSET,
) -> Event:
    if name is not None:
        event.name = name.strip() or event.name
    if event_date is not None or event_date is None:
        # Explicit null is allowed to clear — but to distinguish "not
        # provided" vs "clear to null" callers pass the event_date
        # field only when they mean to change it. We accept a sentinel
        # approach via the Pydantic model (None always means clear).
        event.event_date = event_date
    if occasion is not None:
        event.occasion = occasion.strip() or "other"
    if attendee_count is not None:
        event.attendee_count = max(0, int(attendee_count))
    if notes is not None:
        event.notes = notes
    if status is not None:
        event.status = status.strip() or event.status
    if attendees is not None:
        _sync_attendees(session, event, attendees, household_id=household_id)
    if auto_merge_grocery is not _UNSET:
        event.auto_merge_grocery = bool(auto_merge_grocery)
    return event


def _sync_attendees(
    session: Session,
    event: Event,
    attendees: Iterable[tuple[str, int]],
    *,
    household_id: str,
) -> None:
    """Replace the event's attendee list with the given (guest_id, plus_ones)
    pairs. Guest ownership is validated — callers from a different
    household can't attach arbitrary guest_ids.
    """
    seen: dict[str, int] = {}
    for guest_id, plus_ones in attendees:
        seen[guest_id] = max(0, int(plus_ones))

    # Delete rows no longer present
    for existing in list(event.attendees):
        if existing.guest_id not in seen:
            session.delete(existing)

    # Upsert remaining
    current_by_guest = {row.guest_id: row for row in event.attendees if row.guest_id in seen}
    for guest_id, plus_ones in seen.items():
        # Confirm household ownership — guard against spoofed IDs.
        guest = session.get(Guest, guest_id)
        if guest is None or guest.household_id != household_id:
            raise ValueError(f"Guest {guest_id} not owned by household")
        row = current_by_guest.get(guest_id)
        if row is None:
            session.add(EventAttendee(event_id=event.id, guest_id=guest_id, plus_ones=plus_ones))
        else:
            row.plus_ones = plus_ones


def delete_event(session: Session, event: Event) -> None:
    session.delete(event)


# ---------------------------------------------------------------------
# Event meal CRUD
# ---------------------------------------------------------------------

def replace_event_meals(
    session: Session,
    event: Event,
    meals: list[dict],
    *,
    preserve_manual: bool = False,
) -> list[EventMeal]:
    """Recreate the event's meal list from the payload.

    When `preserve_manual=True`, meals that were manually added (either
    by the user or pre-assigned to a guest — both flagged by
    `ai_generated=False`) are kept and the AI-generated dishes are
    replaced around them. This is how a user can say "Kirsten is
    bringing salad" and regenerate the rest of the menu without
    clobbering the assignment.
    """
    if preserve_manual:
        manual = [m for m in event.meals if not m.ai_generated]
        for existing in list(event.meals):
            if existing.ai_generated:
                session.delete(existing)
        session.flush()
        # Manual rows keep their original sort_order; AI rows get
        # appended after them.
        start_index = max((m.sort_order for m in manual), default=-1) + 1
    else:
        manual = []
        for existing in list(event.meals):
            session.delete(existing)
        session.flush()
        start_index = 0

    rows: list[EventMeal] = list(manual)
    for index, entry in enumerate(meals):
        meal = EventMeal(
            event_id=event.id,
            role=str(entry.get("role", "main")),
            recipe_id=entry.get("recipe_id"),
            recipe_name=str(entry.get("recipe_name", "")).strip() or "Untitled dish",
            servings=entry.get("servings"),
            scale_multiplier=float(entry.get("scale_multiplier", 1.0) or 1.0),
            notes=str(entry.get("notes", "")),
            sort_order=int(entry.get("sort_order", start_index + index)),
            ai_generated=bool(entry.get("ai_generated", True)),
            approved=bool(entry.get("approved", False)),
            assigned_guest_id=entry.get("assigned_guest_id"),
            constraint_coverage=json.dumps(entry.get("constraint_coverage", [])),
        )
        session.add(meal)
        session.flush()
        for ing_index, ing in enumerate(entry.get("ingredients", [])):
            session.add(
                EventMealIngredient(
                    id=f"{meal.id}:{ing_index:04d}",
                    event_meal_id=meal.id,
                    base_ingredient_id=ing.get("base_ingredient_id"),
                    ingredient_variation_id=ing.get("ingredient_variation_id"),
                    ingredient_name=str(ing.get("ingredient_name", "")).strip() or "ingredient",
                    normalized_name=str(ing.get("normalized_name") or ing.get("ingredient_name", "")).lower(),
                    quantity=ing.get("quantity"),
                    unit=str(ing.get("unit", "")),
                    prep=str(ing.get("prep", "")),
                    category=str(ing.get("category", "")),
                    notes=str(ing.get("notes", "")),
                )
            )
        rows.append(meal)
    return rows


def add_event_meal(
    session: Session,
    event: Event,
    *,
    role: str,
    recipe_id: str | None,
    recipe_name: str,
    servings: float | None,
    notes: str,
    assigned_guest_id: str | None, household_id: str,
) -> EventMeal:
    """Add a single manually-entered dish to the event. `ai_generated`
    is set to False so the preserve_manual path of regenerate keeps it.
    Validates guest + recipe ownership to prevent spoofed IDs."""
    if assigned_guest_id:
        guest = session.get(Guest, assigned_guest_id)
        if guest is None or guest.household_id != household_id:
            raise ValueError("Assigned guest not owned by household")
    if recipe_id:
        # Recipe ownership is validated via the FK existence — Recipe
        # is household-scoped. We verify lightly here to avoid
        # attaching someone else's recipe.
        from app.models import Recipe as _Recipe

        recipe = session.get(_Recipe, recipe_id)
        if recipe is None or recipe.household_id != household_id:
            raise ValueError("Recipe not owned by household")
    next_sort = max((m.sort_order for m in event.meals), default=-1) + 1
    meal = EventMeal(
        event_id=event.id,
        role=role,
        recipe_id=recipe_id,
        recipe_name=recipe_name.strip() or "Untitled dish",
        servings=servings,
        scale_multiplier=1.0,
        notes=notes,
        sort_order=next_sort,
        ai_generated=False,
        approved=False,
        assigned_guest_id=assigned_guest_id,
        constraint_coverage="[]",
    )
    session.add(meal)
    session.flush()
    return meal


def update_event_meal(
    session: Session,
    event: Event,
    meal_id: str,
    *,
    role: str | None = None,
    recipe_id: str | None = None,
    recipe_name: str | None = None,
    servings: float | None = None,
    notes: str | None = None,
    assigned_guest_id: str | None = None,
    clear_assignee: bool = False, household_id: str,
) -> EventMeal:
    meal = next((m for m in event.meals if m.id == meal_id), None)
    if meal is None:
        raise ValueError("Meal not found on this event")
    if role is not None:
        meal.role = role
    if recipe_name is not None:
        meal.recipe_name = recipe_name.strip() or meal.recipe_name
    if recipe_id is not None:
        if recipe_id:
            from app.models import Recipe as _Recipe

            recipe = session.get(_Recipe, recipe_id)
            if recipe is None or recipe.household_id != household_id:
                raise ValueError("Recipe not owned by household")
        meal.recipe_id = recipe_id or None
    if servings is not None:
        meal.servings = servings
    if notes is not None:
        meal.notes = notes
    if clear_assignee:
        meal.assigned_guest_id = None
    elif assigned_guest_id is not None:
        guest = session.get(Guest, assigned_guest_id)
        if guest is None or guest.household_id != household_id:
            raise ValueError("Assigned guest not owned by household")
        meal.assigned_guest_id = assigned_guest_id
    session.flush()
    return meal


def delete_event_meal(session: Session, event: Event, meal_id: str) -> bool:
    meal = next((m for m in event.meals if m.id == meal_id), None)
    if meal is None:
        return False
    session.delete(meal)
    session.flush()
    return True


def clear_event_grocery(session: Session, event: Event) -> None:
    for existing in list(event.grocery_items):
        session.delete(existing)
    session.flush()


# Convenience: produce fresh ids for ingredients without conflicts.
def _ingredient_row_id(meal_id: str, index: int) -> str:
    return f"{meal_id}:{index:04d}"


__all__ = [
    "clear_event_grocery",
    "create_event",
    "delete_event",
    "delete_guest",
    "get_event",
    "get_guest",
    "list_events",
    "list_guests",
    "new_id",
    "replace_event_meals",
    "update_event",
    "upsert_guest",
]
