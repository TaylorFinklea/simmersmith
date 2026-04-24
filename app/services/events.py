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

def list_guests(session: Session, user_id: str, *, include_inactive: bool = False) -> list[Guest]:
    stmt = select(Guest).where(Guest.user_id == user_id).order_by(Guest.name)
    if not include_inactive:
        stmt = stmt.where(Guest.active.is_(True))
    return list(session.scalars(stmt).all())


def get_guest(session: Session, user_id: str, guest_id: str) -> Guest | None:
    return session.scalar(
        select(Guest).where(Guest.id == guest_id, Guest.user_id == user_id)
    )


def upsert_guest(
    session: Session,
    user_id: str,
    *,
    guest_id: str | None,
    name: str,
    relationship_label: str = "",
    dietary_notes: str = "",
    allergies: str = "",
    active: bool = True,
) -> Guest:
    guest: Guest | None = None
    if guest_id:
        guest = get_guest(session, user_id, guest_id)
        if guest is None:
            raise ValueError("Guest not found")
    if guest is None:
        guest = Guest(user_id=user_id, name=name)
        session.add(guest)
    guest.name = name.strip()
    guest.relationship_label = relationship_label.strip()
    guest.dietary_notes = dietary_notes.strip()
    guest.allergies = allergies.strip()
    guest.active = active
    session.flush()
    return guest


def delete_guest(session: Session, user_id: str, guest_id: str) -> bool:
    guest = get_guest(session, user_id, guest_id)
    if guest is None:
        return False
    session.delete(guest)
    return True


# ---------------------------------------------------------------------
# Event CRUD
# ---------------------------------------------------------------------

def list_events(session: Session, user_id: str) -> list[Event]:
    stmt = (
        select(Event)
        .where(Event.user_id == user_id)
        .order_by(Event.event_date.is_(None), Event.event_date, Event.created_at.desc())
        .options(selectinload(Event.meals), selectinload(Event.attendees))
    )
    return list(session.scalars(stmt).all())


def get_event(session: Session, user_id: str, event_id: str) -> Event | None:
    return session.scalar(
        select(Event)
        .where(Event.id == event_id, Event.user_id == user_id)
        .options(
            selectinload(Event.attendees).selectinload(EventAttendee.guest),
            selectinload(Event.meals).selectinload(EventMeal.inline_ingredients),
            selectinload(Event.grocery_items),
        )
    )


def create_event(
    session: Session,
    user_id: str,
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
        name=name.strip() or "Untitled event",
        event_date=event_date,
        occasion=occasion.strip() or "other",
        attendee_count=max(0, int(attendee_count)),
        notes=notes,
    )
    session.add(event)
    session.flush()
    _sync_attendees(session, event, attendees, user_id=user_id)
    return event


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
    user_id: str,
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
        _sync_attendees(session, event, attendees, user_id=user_id)
    return event


def _sync_attendees(
    session: Session,
    event: Event,
    attendees: Iterable[tuple[str, int]],
    *,
    user_id: str,
) -> None:
    """Replace the event's attendee list with the given (guest_id, plus_ones)
    pairs. Guest ownership is validated — callers from a different user
    can't attach arbitrary guest_ids.
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
        # Confirm ownership — guard against spoofed IDs.
        guest = session.get(Guest, guest_id)
        if guest is None or guest.user_id != user_id:
            raise ValueError(f"Guest {guest_id} not owned by user")
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
) -> list[EventMeal]:
    """Wipe the event's current meals and recreate from the provided
    payload list. Used by the AI menu generation flow and manual edits.
    Each dict should carry: role, recipe_id?, recipe_name, servings?,
    notes, constraint_coverage (list[str]), ingredients (list[dict]).
    """
    for existing in list(event.meals):
        session.delete(existing)
    session.flush()

    rows: list[EventMeal] = []
    for index, entry in enumerate(meals):
        meal = EventMeal(
            event_id=event.id,
            role=str(entry.get("role", "main")),
            recipe_id=entry.get("recipe_id"),
            recipe_name=str(entry.get("recipe_name", "")).strip() or "Untitled dish",
            servings=entry.get("servings"),
            scale_multiplier=float(entry.get("scale_multiplier", 1.0) or 1.0),
            notes=str(entry.get("notes", "")),
            sort_order=int(entry.get("sort_order", index)),
            ai_generated=bool(entry.get("ai_generated", True)),
            approved=bool(entry.get("approved", False)),
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
