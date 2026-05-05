"""M28 phase 2 — event pantry supplement CRUD.

Each supplement is keyed by `(event_id, pantry_item_id)` — at most
one supplement per pantry item per event. After any mutation we
re-run `regenerate_event_grocery` so the supplement flows into the
event's grocery list, and (when `auto_merge_grocery` is on for the
event) onward into the linked week's `event_quantity` column.
"""
from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Event, EventPantrySupplement, Staple


def list_supplements(session: Session, *, event: Event) -> list[EventPantrySupplement]:
    return list(event.pantry_supplements)


def get_supplement(
    session: Session, *, event_id: str, supplement_id: str
) -> EventPantrySupplement | None:
    return session.scalar(
        select(EventPantrySupplement).where(
            EventPantrySupplement.id == supplement_id,
            EventPantrySupplement.event_id == event_id,
        )
    )


def add_supplement(
    session: Session,
    *,
    event: Event,
    pantry_item_id: str,
    quantity: float,
    unit: str = "",
    notes: str = "",
    household_id: str,
) -> EventPantrySupplement:
    if quantity <= 0:
        raise ValueError("quantity must be positive")
    pantry_item = session.scalar(
        select(Staple).where(
            Staple.id == pantry_item_id,
            Staple.household_id == household_id,
        )
    )
    if pantry_item is None:
        raise ValueError("Pantry item not found")
    existing = session.scalar(
        select(EventPantrySupplement).where(
            EventPantrySupplement.event_id == event.id,
            EventPantrySupplement.pantry_item_id == pantry_item_id,
        )
    )
    if existing is not None:
        raise ValueError(
            "A supplement for this pantry item already exists on the event — "
            "edit it instead of creating a duplicate."
        )
    supplement = EventPantrySupplement(
        event_id=event.id,
        pantry_item_id=pantry_item_id,
        quantity=float(quantity),
        unit=unit or "",
        notes=notes or "",
    )
    session.add(supplement)
    session.flush()
    return supplement


def update_supplement(
    session: Session,
    *,
    supplement: EventPantrySupplement,
    fields: dict[str, Any],
) -> EventPantrySupplement:
    if "quantity" in fields and fields["quantity"] is not None:
        if float(fields["quantity"]) <= 0:
            raise ValueError("quantity must be positive")
        supplement.quantity = float(fields["quantity"])
    if "unit" in fields and fields["unit"] is not None:
        supplement.unit = str(fields["unit"])
    if "notes" in fields and fields["notes"] is not None:
        supplement.notes = str(fields["notes"])
    session.flush()
    return supplement


def delete_supplement(session: Session, *, supplement: EventPantrySupplement) -> None:
    session.delete(supplement)
    session.flush()
