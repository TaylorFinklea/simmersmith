from __future__ import annotations

import json
from typing import Iterable

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import GroceryItem, PricingRun, RetailerPrice, Week, utcnow
from app.schemas import PricingImportItem, PricingImportRequest
from app.services.presenters import pricing_payload
from app.services.weeks import get_week


def pricing_items_for_week(session: Session, week_id: str) -> list[GroceryItem]:
    return session.scalars(select(GroceryItem).where(GroceryItem.week_id == week_id)).all()


def review_notes_for_prices(prices: Iterable[RetailerPrice]) -> str:
    notes: list[str] = []
    seen: set[str] = set()
    for price in sorted(prices, key=lambda row: row.retailer):
        note = price.review_note.strip()
        if not note and price.status == "review":
            note = f"{price.retailer} review"
        if not note and price.status == "unavailable":
            note = f"{price.retailer} unavailable"
        if not note or note in seen:
            continue
        seen.add(note)
        notes.append(note)
    return "; ".join(notes)


def build_retailer_price(entry: PricingImportItem) -> RetailerPrice:
    return RetailerPrice(
        grocery_item_id=entry.grocery_item_id,
        retailer=entry.retailer,
        status=entry.status,
        store_name=entry.store_name,
        product_name=entry.product_name,
        package_size=entry.package_size,
        unit_price=entry.unit_price,
        line_price=entry.line_price,
        product_url=entry.product_url,
        availability=entry.availability,
        candidate_score=entry.candidate_score,
        review_note=entry.review_note,
        raw_query=entry.raw_query,
        scraped_at=entry.scraped_at or utcnow(),
    )


def import_pricing(session: Session, week: Week, payload: PricingImportRequest) -> dict[str, object]:
    if week.status not in {"approved", "priced"}:
        raise ValueError("Week must be approved before pricing can be imported.")

    week_items = pricing_items_for_week(session, week.id)
    item_lookup = {item.id: item for item in week_items}
    pricing_run = PricingRun(week_id=week.id, status="running", item_count=len(payload.items))
    session.add(pricing_run)
    session.flush()

    try:
        for entry in payload.items:
            if entry.grocery_item_id not in item_lookup:
                raise ValueError(f"Unknown grocery item '{entry.grocery_item_id}' for week {week.id}.")

        if payload.replace_existing:
            if week_items:
                session.execute(
                    delete(RetailerPrice).where(RetailerPrice.grocery_item_id.in_([item.id for item in week_items]))
                )
            for item in week_items:
                item.review_flag = ""

        seen_pairs: set[tuple[str, str]] = set()
        for entry in payload.items:
            pair = (entry.grocery_item_id, entry.retailer)
            if pair in seen_pairs:
                raise ValueError(f"Duplicate pricing import row for item {entry.grocery_item_id} and {entry.retailer}.")
            seen_pairs.add(pair)

            if not payload.replace_existing:
                session.execute(
                    delete(RetailerPrice).where(
                        RetailerPrice.grocery_item_id == entry.grocery_item_id,
                        RetailerPrice.retailer == entry.retailer,
                    )
                )

            session.add(build_retailer_price(entry))

        session.flush()
        session.expire_all()

        refreshed_week = get_week(session, week.user_id, week.id)
        if refreshed_week is None:
            raise ValueError(f"Week {week.id} not found after pricing import.")

        for item in refreshed_week.grocery_items:
            item.review_flag = review_notes_for_prices(item.retailer_prices)

        refreshed_week.status = "priced"
        refreshed_week.priced_at = utcnow()
        pricing_run.status = "completed"
        pricing_run.completed_at = utcnow()
        session.flush()

        response_payload = pricing_payload(refreshed_week)
        pricing_run.totals_json = json.dumps(response_payload["totals"] if response_payload else {})
        session.flush()
        return response_payload or {"week_id": refreshed_week.id, "week_start": refreshed_week.week_start, "totals": {}, "items": []}
    except Exception as exc:
        pricing_run.status = "failed"
        pricing_run.error = str(exc)
        pricing_run.completed_at = utcnow()
        session.flush()
        raise
