"""M25 ingredient catalog governance — submission lifecycle helpers.

States:
- `approved` — global / master list. household_id is NULL.
- `submitted` — household authored, waiting on admin review. Only
  the authoring household sees it; admin tooling can promote or
  reject.
- `household_only` — household authored, never submitted. Stays
  private to the household forever.
- `rejected` — admin declined the submission. Kept for audit and so
  the authoring household can see why.

Authoring household (`household_id`) is set when the row is created
(`ensure_base_ingredient(..., household_id=X)`). Promotion to
`approved` clears `household_id` (the row joins the global catalog).
"""
from __future__ import annotations

from sqlalchemy.orm import Session

from app.models import BaseIngredient
from app.models._base import utcnow


VALID_STATUSES = {"approved", "submitted", "household_only", "rejected"}


def submit_for_adoption(
    session: Session, *, ingredient_id: str, household_id: str
) -> BaseIngredient:
    """Household author flips a private row from `household_only` to
    `submitted`. Validates ownership — a household can't submit
    another household's row, and `approved` rows can't be re-submitted.
    """
    item = session.get(BaseIngredient, ingredient_id)
    if item is None:
        raise ValueError("Ingredient not found")
    if item.household_id != household_id:
        raise ValueError("Only the authoring household can submit this row")
    if item.submission_status != "household_only":
        raise ValueError(
            f"Cannot submit ingredient in status '{item.submission_status}'"
        )
    item.submission_status = "submitted"
    item.updated_at = utcnow()
    session.flush()
    return item


def approve_submission(session: Session, *, ingredient_id: str) -> BaseIngredient:
    """Admin promotes a `submitted` row to `approved`. Clears
    `household_id` so the row becomes globally visible.
    """
    item = session.get(BaseIngredient, ingredient_id)
    if item is None:
        raise ValueError("Ingredient not found")
    if item.submission_status not in {"submitted", "household_only"}:
        raise ValueError(
            f"Cannot approve ingredient in status '{item.submission_status}'"
        )
    item.submission_status = "approved"
    item.household_id = None
    # Provisional flag was the legacy "I made this up because I had to"
    # marker. Clear it on approval — admin has confirmed the row is
    # canonical.
    item.provisional = False
    item.updated_at = utcnow()
    session.flush()
    return item


def reject_submission(
    session: Session,
    *,
    ingredient_id: str,
    reason: str = "",
) -> BaseIngredient:
    """Admin declines a submitted row. Stays visible to the authoring
    household so they can see the rejection reason; doesn't enter the
    global catalog.
    """
    item = session.get(BaseIngredient, ingredient_id)
    if item is None:
        raise ValueError("Ingredient not found")
    if item.submission_status != "submitted":
        raise ValueError(
            f"Cannot reject ingredient in status '{item.submission_status}'"
        )
    item.submission_status = "rejected"
    if reason:
        existing_notes = (item.notes or "").strip()
        marker = f"[admin-rejected] {reason.strip()}"
        item.notes = (existing_notes + "\n" + marker).strip() if existing_notes else marker
    item.updated_at = utcnow()
    session.flush()
    return item
