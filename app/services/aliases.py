"""M26 Phase 3 — per-household term aliases service.

Aliases are stored term-lowercase so case-insensitive matches collide
on a single slot ("chx", "CHX", "Chx" → same row). Both the week
planner and the assistant inject the alias map as a "treat term X as
expansion Y" preamble in their system prompts so the AI doesn't have
to ask "what does chx mean?" every time.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.aliases import HouseholdTermAlias


def _normalize_term(term: str) -> str:
    return (term or "").strip().lower()


def list_aliases(session: Session, *, household_id: str) -> list[HouseholdTermAlias]:
    return list(
        session.scalars(
            select(HouseholdTermAlias)
            .where(HouseholdTermAlias.household_id == household_id)
            .order_by(HouseholdTermAlias.term)
        ).all()
    )


def aliases_map(session: Session, *, household_id: str) -> dict[str, str]:
    """Plain dict the prompt assemblers can render directly."""
    return {a.term: a.expansion for a in list_aliases(session, household_id=household_id)}


def upsert_alias(
    session: Session,
    *,
    household_id: str,
    term: str,
    expansion: str,
    notes: str = "",
) -> HouseholdTermAlias:
    """Insert or update an alias by `(household_id, term)`. Term is
    case-normalized; expansion preserves original casing so an alias
    can resolve to "Trader Joe's" with the apostrophe intact.
    """
    cleaned_term = _normalize_term(term)
    cleaned_expansion = (expansion or "").strip()
    if not cleaned_term:
        raise ValueError("term required")
    if not cleaned_expansion:
        raise ValueError("expansion required")

    existing = session.scalar(
        select(HouseholdTermAlias).where(
            HouseholdTermAlias.household_id == household_id,
            HouseholdTermAlias.term == cleaned_term,
        )
    )
    if existing is not None:
        existing.expansion = cleaned_expansion
        existing.notes = notes or ""
        session.flush()
        return existing

    alias = HouseholdTermAlias(
        household_id=household_id,
        term=cleaned_term,
        expansion=cleaned_expansion,
        notes=notes or "",
    )
    session.add(alias)
    session.flush()
    return alias


def delete_alias(session: Session, *, household_id: str, term: str) -> bool:
    """Delete by term. Returns True if a row existed, False otherwise."""
    cleaned_term = _normalize_term(term)
    existing = session.scalar(
        select(HouseholdTermAlias).where(
            HouseholdTermAlias.household_id == household_id,
            HouseholdTermAlias.term == cleaned_term,
        )
    )
    if existing is None:
        return False
    session.delete(existing)
    session.flush()
    return True
