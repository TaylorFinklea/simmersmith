"""M28 — pantry service.

Pantry items live on the existing `staples` table (extended in
migration `0034`). All pantry items are ALWAYS filtered from
meal-driven grocery aggregation (see
`app/services/grocery.py:staple_names`). The pantry layer adds:

- typical purchase quantity (informational only)
- recurring auto-add to weekly grocery, gated by cadence
  (`weekly` / `biweekly` / `monthly`) and `last_applied_at`

`apply_pantry_recurrings(session, week)` walks the household's
recurring pantry items, decides which are due based on the
cadence + last_applied_at + week_start gap, and adds each due
item as a `user_added` grocery row carrying
`source_meals="pantry:recurring:<id>"`. The marker lets the
function be idempotent — calling it twice on the same week won't
double up.

Pre-existing staples (no recurring) are unaffected.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import GroceryItem, Staple, Week
from app.services.grocery import normalize_name, normalize_unit
from app.services.weeks import invalidate_week


_CADENCE_MIN_DAYS = {
    "weekly": 0,        # always apply
    "biweekly": 13,     # at least 13 days since last apply
    "monthly": 27,      # at least 27 days since last apply
}

_PANTRY_SOURCE_PREFIX = "pantry:recurring:"


def serialize_categories(categories: list[str]) -> str:
    """M29 build 56: pantry categories live in `Staple.category` as a
    comma-joined string (legacy single-value column). The API surface
    exposes them as a list — these helpers do the round-trip without
    a schema migration."""
    cleaned: list[str] = []
    seen: set[str] = set()
    for raw in categories or []:
        value = (raw or "").strip()
        if not value:
            continue
        # Comma is the separator; strip embedded commas so a careless
        # "dairy, freezer" entry doesn't desync.
        value = value.replace(",", " ")
        normalized = value.lower()
        if normalized in seen:
            continue
        seen.add(normalized)
        cleaned.append(value)
    return ", ".join(cleaned)


def parse_categories(stored: str) -> list[str]:
    if not stored:
        return []
    return [part.strip() for part in stored.split(",") if part.strip()]


def list_pantry_items(session: Session, *, household_id: str) -> list[Staple]:
    return list(
        session.scalars(
            select(Staple)
            .where(Staple.household_id == household_id)
            .order_by(Staple.staple_name)
        ).all()
    )


def get_pantry_item(session: Session, *, household_id: str, item_id: str) -> Staple | None:
    return session.scalar(
        select(Staple).where(Staple.id == item_id, Staple.household_id == household_id)
    )


def add_pantry_item(
    session: Session,
    *,
    user_id: str,
    household_id: str,
    name: str,
    notes: str = "",
    is_active: bool = True,
    typical_quantity: float | None = None,
    typical_unit: str = "",
    recurring_quantity: float | None = None,
    recurring_unit: str = "",
    recurring_cadence: str = "none",
    category: str = "",
    categories: list[str] | None = None,
    normalized_name_override: str = "",
) -> Staple:
    cleaned = (name or "").strip()
    if not cleaned:
        raise ValueError("staple_name required")
    normalized = normalize_name(normalized_name_override or cleaned)
    if not normalized:
        raise ValueError("staple_name produced an empty normalized name")
    existing = session.scalar(
        select(Staple).where(
            Staple.user_id == user_id,
            Staple.normalized_name == normalized,
        )
    )
    if existing is not None:
        raise ValueError("Pantry item with that name already exists")
    # `categories` is the new multi-value list; `category` is the
    # legacy single-string entry point. When both are provided, the
    # list wins; otherwise fall back to the single value.
    if categories is not None:
        category_value = serialize_categories(categories)
    else:
        category_value = (category or "").strip()
    item = Staple(
        user_id=user_id,
        household_id=household_id,
        staple_name=cleaned,
        normalized_name=normalized,
        notes=notes,
        is_active=is_active,
        typical_quantity=typical_quantity,
        typical_unit=normalize_unit(typical_unit) if typical_unit else "",
        recurring_quantity=recurring_quantity,
        recurring_unit=normalize_unit(recurring_unit) if recurring_unit else "",
        recurring_cadence=recurring_cadence if recurring_cadence in {"none", "weekly", "biweekly", "monthly"} else "none",
        category=category_value,
    )
    session.add(item)
    session.flush()
    return item


def update_pantry_item(
    session: Session,
    *,
    item: Staple,
    fields: dict[str, Any],
) -> Staple:
    if "staple_name" in fields and fields["staple_name"] is not None:
        cleaned = str(fields["staple_name"]).strip()
        if not cleaned:
            raise ValueError("staple_name cannot be empty")
        item.staple_name = cleaned
        item.normalized_name = normalize_name(cleaned)
    if "notes" in fields and fields["notes"] is not None:
        item.notes = fields["notes"]
    if "is_active" in fields and fields["is_active"] is not None:
        item.is_active = bool(fields["is_active"])
    if fields.get("clear_typical_quantity"):
        item.typical_quantity = None
    elif "typical_quantity" in fields and fields["typical_quantity"] is not None:
        item.typical_quantity = float(fields["typical_quantity"])
    if "typical_unit" in fields and fields["typical_unit"] is not None:
        item.typical_unit = normalize_unit(fields["typical_unit"]) if fields["typical_unit"] else ""
    if fields.get("clear_recurring_quantity"):
        item.recurring_quantity = None
    elif "recurring_quantity" in fields and fields["recurring_quantity"] is not None:
        item.recurring_quantity = float(fields["recurring_quantity"])
    if "recurring_unit" in fields and fields["recurring_unit"] is not None:
        item.recurring_unit = normalize_unit(fields["recurring_unit"]) if fields["recurring_unit"] else ""
    if "recurring_cadence" in fields and fields["recurring_cadence"] is not None:
        cadence = str(fields["recurring_cadence"])
        if cadence in {"none", "weekly", "biweekly", "monthly"}:
            item.recurring_cadence = cadence
    if "categories" in fields and fields["categories"] is not None:
        item.category = serialize_categories(list(fields["categories"]))
    elif "category" in fields and fields["category"] is not None:
        # Legacy single-string path stays accepted for back-compat.
        item.category = str(fields["category"])
    session.flush()
    return item


def delete_pantry_item(session: Session, *, item: Staple) -> None:
    session.delete(item)
    session.flush()


def _is_due(item: Staple, *, week_start: date, now: datetime) -> bool:
    """Decide whether a pantry item's recurring should fire for the
    given week. `weekly` always fires; `biweekly` / `monthly` need
    the gap from `last_applied_at` to be wide enough."""
    if item.recurring_cadence == "none":
        return False
    if not item.is_active:
        return False
    if item.recurring_quantity is None or item.recurring_quantity <= 0:
        return False
    min_days = _CADENCE_MIN_DAYS.get(item.recurring_cadence)
    if min_days is None:
        return False
    if item.last_applied_at is None or min_days == 0:
        return True
    gap = (now - item.last_applied_at).days
    return gap >= min_days


def apply_pantry_recurrings(
    session: Session,
    *,
    week: Week,
    household_id: str,
    now: datetime | None = None,
) -> list[GroceryItem]:
    """Idempotent: walk the household's recurring pantry items, add a
    `user_added` grocery row for each one that's due. Returns the rows
    that were added (or already present and considered current).

    Re-running the function on the same week is a no-op for items that
    already have a recurring row (matched by `source_meals` marker).
    """
    invalidate_week(session, week)
    now_ts = now or datetime.now(timezone.utc)

    items = list(
        session.scalars(
            select(Staple).where(
                Staple.household_id == household_id,
                Staple.recurring_cadence != "none",
                Staple.is_active.is_(True),
            )
        ).all()
    )

    existing_rows = {
        item.source_meals: item
        for item in session.scalars(
            select(GroceryItem).where(
                GroceryItem.week_id == week.id,
                GroceryItem.is_user_added.is_(True),
            )
        ).all()
        if item.source_meals.startswith(_PANTRY_SOURCE_PREFIX)
    }

    landed: list[GroceryItem] = []
    for item in items:
        if not _is_due(item, week_start=week.week_start, now=now_ts):
            continue
        marker = f"{_PANTRY_SOURCE_PREFIX}{item.id}"
        existing = existing_rows.get(marker)
        if existing is not None and not existing.is_user_removed:
            landed.append(existing)
            continue
        unit = item.recurring_unit or item.typical_unit or ""
        row = GroceryItem(
            week_id=week.id,
            ingredient_name=item.staple_name,
            normalized_name=item.normalized_name,
            total_quantity=item.recurring_quantity,
            unit=unit,
            quantity_text="",
            category=item.category or "",
            source_meals=marker,
            notes="Recurring pantry restock",
            review_flag="",
            resolution_status="locked" if item.normalized_name else "unresolved",
            is_user_added=True,
        )
        session.add(row)
        item.last_applied_at = now_ts
        landed.append(row)
    session.flush()
    return landed
