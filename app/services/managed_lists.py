from __future__ import annotations

from collections.abc import Iterable

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import ManagedListItem
from app.services.recipe_templates import DEFAULT_TEMPLATE_ID, list_templates, template_payload
from app.services.grocery import normalize_name


MANAGED_LIST_DEFAULTS: dict[str, list[str]] = {
    "cuisine": [
        "American",
        "Chinese",
        "Indian",
        "Italian",
        "Japanese",
        "Korean",
        "Mediterranean",
        "Mexican",
        "Thai",
        "Vietnamese",
    ],
    "tag": [
        "Family favorite",
        "High protein",
        "Kid friendly",
        "Low carb",
        "Meal prep",
        "Quick",
        "Vegetarian",
        "Weeknight",
    ],
    "unit": [
        "bag",
        "bunch",
        "can",
        "clove",
        "cup",
        "ea",
        "fl oz",
        "gal",
        "lb",
        "oz",
        "pkg",
        "slice",
        "tbsp",
        "tsp",
    ],
}


def normalize_managed_name(value: str) -> str:
    return normalize_name(value)


def list_items(session: Session, kind: str) -> list[ManagedListItem]:
    ensure_defaults(session)
    statement = select(ManagedListItem).where(ManagedListItem.kind == kind).order_by(ManagedListItem.name)
    return list(session.scalars(statement).all())


def create_item(session: Session, kind: str, name: str) -> ManagedListItem:
    cleaned = name.strip()
    if not cleaned:
        raise ValueError("Name is required")
    normalized_name = normalize_managed_name(cleaned)
    existing = session.scalar(
        select(ManagedListItem).where(
            ManagedListItem.kind == kind,
            ManagedListItem.normalized_name == normalized_name,
        )
    )
    if existing is not None:
        return existing
    item = ManagedListItem(kind=kind, name=cleaned, normalized_name=normalized_name)
    session.add(item)
    session.flush()
    return item


def sync_items(session: Session, kind: str, names: Iterable[str]) -> list[str]:
    canonical: list[str] = []
    seen: set[str] = set()
    for name in names:
        cleaned = str(name).strip()
        if not cleaned:
            continue
        normalized_name = normalize_managed_name(cleaned)
        if normalized_name in seen:
            continue
        seen.add(normalized_name)
        item = create_item(session, kind, cleaned)
        canonical.append(item.name)
    return canonical


def metadata_payload(session: Session) -> dict[str, object]:
    ensure_defaults(session)
    items = list(session.scalars(select(ManagedListItem).order_by(ManagedListItem.kind, ManagedListItem.name)).all())
    templates = list_templates(session)
    updated_at = max((item.updated_at for item in items), default=None)
    template_updated_at = max((template.updated_at for template in templates), default=None)
    if template_updated_at is not None and (updated_at is None or template_updated_at > updated_at):
        updated_at = template_updated_at
    payload_by_kind: dict[str, list[dict[str, object]]] = {"cuisine": [], "tag": [], "unit": []}
    for item in items:
        payload_by_kind.setdefault(item.kind, []).append(
            {
                "item_id": item.id,
                "kind": item.kind,
                "name": item.name,
                "normalized_name": item.normalized_name,
                "updated_at": item.updated_at,
            }
        )
    return {
        "updated_at": updated_at,
        "cuisines": payload_by_kind.get("cuisine", []),
        "tags": payload_by_kind.get("tag", []),
        "units": payload_by_kind.get("unit", []),
        "default_template_id": DEFAULT_TEMPLATE_ID,
        "templates": [template_payload(template) for template in templates],
    }


def ensure_defaults(session: Session) -> None:
    for kind, names in MANAGED_LIST_DEFAULTS.items():
        for name in names:
            create_item(session, kind, name)
    session.flush()
