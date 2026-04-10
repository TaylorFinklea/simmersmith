from __future__ import annotations

from datetime import date, timedelta

from sqlalchemy import delete, select
from sqlalchemy.orm import Session, selectinload

from app.config import get_settings
from app.models import ExportRun, GroceryItem, PricingRun, RetailerPrice, Week, WeekChangeBatch, WeekMeal, utcnow

SLOT_ORDER = {"breakfast": 0, "lunch": 1, "dinner": 2, "snack": 3}


def get_current_week(session: Session) -> Week | None:
    statement = (
        select(Week)
        .options(
            selectinload(Week.meals).selectinload(WeekMeal.recipe),
            selectinload(Week.meals).selectinload(WeekMeal.inline_ingredients),
            selectinload(Week.grocery_items).selectinload(GroceryItem.retailer_prices),
            selectinload(Week.change_batches).selectinload(WeekChangeBatch.events),
            selectinload(Week.feedback_entries),
            selectinload(Week.export_runs).selectinload(ExportRun.items),
        )
        .order_by(Week.week_start.desc())
        .limit(1)
    )
    return session.scalar(statement)


def get_week_by_start(session: Session, week_start: date) -> Week | None:
    statement = (
        select(Week)
        .where(Week.week_start == week_start)
        .options(
            selectinload(Week.meals).selectinload(WeekMeal.recipe),
            selectinload(Week.meals).selectinload(WeekMeal.inline_ingredients),
            selectinload(Week.grocery_items).selectinload(GroceryItem.retailer_prices),
            selectinload(Week.change_batches).selectinload(WeekChangeBatch.events),
            selectinload(Week.feedback_entries),
            selectinload(Week.export_runs).selectinload(ExportRun.items),
        )
    )
    return session.scalar(statement)


def get_week(session: Session, week_id: str) -> Week | None:
    statement = (
        select(Week)
        .where(Week.id == week_id)
        .options(
            selectinload(Week.meals).selectinload(WeekMeal.recipe),
            selectinload(Week.meals).selectinload(WeekMeal.inline_ingredients),
            selectinload(Week.grocery_items).selectinload(GroceryItem.retailer_prices),
            selectinload(Week.ai_runs),
            selectinload(Week.pricing_runs),
            selectinload(Week.change_batches).selectinload(WeekChangeBatch.events),
            selectinload(Week.feedback_entries),
            selectinload(Week.export_runs).selectinload(ExportRun.items),
        )
    )
    return session.scalar(statement)


def list_weeks(session: Session, limit: int = 12) -> list[Week]:
    statement = (
        select(Week)
        .options(
            selectinload(Week.meals),
            selectinload(Week.grocery_items).selectinload(GroceryItem.retailer_prices),
            selectinload(Week.change_batches),
            selectinload(Week.feedback_entries),
            selectinload(Week.export_runs),
        )
        .order_by(Week.week_start.desc())
        .limit(limit)
    )
    return list(session.scalars(statement).all())


def create_or_get_week(session: Session, week_start: date, notes: str = "") -> Week:
    existing = session.scalar(select(Week).where(Week.week_start == week_start))
    if existing is not None:
        if notes:
            existing.notes = notes
        return existing

    week = Week(
        user_id=get_settings().local_user_id,
        week_start=week_start,
        week_end=week_start + timedelta(days=6),
        status="staging",
        notes=notes,
    )
    session.add(week)
    session.flush()
    return week


def invalidate_week(session: Session, week: Week) -> None:
    week.status = "staging"
    week.ready_for_ai_at = None
    week.approved_at = None
    week.priced_at = None
    week.updated_at = utcnow()
    session.execute(
        delete(PricingRun).where(PricingRun.week_id == week.id)
    )
    grocery_ids = session.scalars(select(GroceryItem.id).where(GroceryItem.week_id == week.id)).all()
    if grocery_ids:
        session.execute(delete(RetailerPrice).where(RetailerPrice.grocery_item_id.in_(grocery_ids)))


def finalize_week(week: Week) -> Week:
    week.status = "approved"
    week.approved_at = utcnow()
    week.updated_at = utcnow()
    return week


def mark_week_ready_for_ai(week: Week) -> Week:
    week.status = "ready_for_ai"
    week.ready_for_ai_at = utcnow()
    week.updated_at = utcnow()
    return week


def slot_sort(slot: str) -> int:
    return SLOT_ORDER.get(slot.lower(), 99)
