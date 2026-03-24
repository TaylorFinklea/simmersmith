from __future__ import annotations

import json
from datetime import timezone

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.models import ExportItem, ExportRun, GroceryItem, Week, utcnow
from app.schemas import ExportCompleteRequest, ExportCreateRequest
from app.services.weeks import get_week

RETAILER_LABELS = {
    "aldi": "ALDI",
    "walmart": "WALMART",
    "sams_club": "SAM'S",
}
RETAILER_SORT = {"aldi": 0, "walmart": 1, "sams_club": 2}
SLOT_LABELS = {"breakfast": "Breakfast", "lunch": "Lunch", "dinner": "Dinner"}


def quantity_label(item: GroceryItem) -> str:
    if item.total_quantity is not None:
        return f"{item.total_quantity:g}{f' {item.unit}' if item.unit else ''}"
    return item.quantity_text or "Review"


def _best_price(item: GroceryItem):
    matched = [price for price in item.retailer_prices if price.status == "matched" and price.line_price is not None]
    return sorted(matched, key=lambda price: (price.line_price or 0, price.retailer))[0] if matched else None


def list_export_runs(session: Session, week_id: str) -> list[ExportRun]:
    return list(
        session.scalars(
            select(ExportRun)
            .options(selectinload(ExportRun.items))
            .where(ExportRun.week_id == week_id)
            .order_by(ExportRun.created_at.desc())
        ).all()
    )


def get_export_run(session: Session, export_id: str) -> ExportRun | None:
    return session.scalar(select(ExportRun).options(selectinload(ExportRun.items)).where(ExportRun.id == export_id))


def export_item_payload(item: ExportItem) -> dict[str, object]:
    return {
        "export_item_id": item.id,
        "sort_order": item.sort_order,
        "list_name": item.list_name,
        "title": item.title,
        "notes": item.notes,
        "metadata_json": item.metadata_json,
        "status": item.status,
    }


def export_run_payload(export_run: ExportRun) -> dict[str, object]:
    ordered_items = sorted(export_run.items, key=lambda item: (item.sort_order, item.title))
    return {
        "export_id": export_run.id,
        "destination": export_run.destination,
        "export_type": export_run.export_type,
        "status": export_run.status,
        "item_count": export_run.item_count,
        "payload_json": export_run.payload_json,
        "error": export_run.error,
        "external_ref": export_run.external_ref,
        "created_at": export_run.created_at,
        "completed_at": export_run.completed_at,
        "updated_at": export_run.completed_at or export_run.created_at,
        "items": [export_item_payload(item) for item in ordered_items],
    }


def export_runs_payload(session: Session, week_id: str) -> list[dict[str, object]]:
    return [export_run_payload(run) for run in list_export_runs(session, week_id)]


def build_meal_plan_export_items(week: Week) -> tuple[list[dict[str, object]], list[str]]:
    items: list[dict[str, object]] = []
    warnings: list[str] = []
    ordered_meals = sorted(week.meals, key=lambda meal: (meal.meal_date, meal.sort_order))
    for index, meal in enumerate([meal for meal in ordered_meals if meal.slot != "snack"]):
        title = f"{meal.day_name} - {SLOT_LABELS.get(meal.slot, meal.slot.title())}: {meal.recipe_name}"
        items.append(
            {
                "sort_order": index,
                "list_name": "Meals",
                "title": title,
                "notes": meal.notes,
                "metadata": {
                    "meal_id": meal.id,
                    "meal_date": meal.meal_date.isoformat(),
                    "slot": meal.slot,
                    "recipe_id": meal.recipe_id,
                },
            }
        )
    return items, warnings


def build_shopping_split_export_items(week: Week) -> tuple[list[dict[str, object]], list[str]]:
    items: list[dict[str, object]] = []
    warnings: list[str] = []

    sorted_grocery = sorted(week.grocery_items, key=lambda item: (item.category, item.ingredient_name))
    matched_items: list[dict[str, object]] = []
    review_items: list[dict[str, object]] = []
    for grocery_item in sorted_grocery:
        best = _best_price(grocery_item)
        notes = ", ".join(part for part in [grocery_item.notes, grocery_item.source_meals] if part)
        if best is None:
            warnings.append(f"Needs review before export: {grocery_item.ingredient_name}")
            review_items.append(
                {
                    "sort_order": 0,
                    "list_name": "Grocery",
                    "title": f"[REVIEW] {grocery_item.ingredient_name} ({quantity_label(grocery_item)})",
                    "notes": notes or "No matched store winner. Check pricing review.",
                    "metadata": {
                        "grocery_item_id": grocery_item.id,
                        "retailer": "",
                        "status": "review",
                    },
                }
            )
            continue

        matched_items.append(
            {
                "sort_order": 0,
                "list_name": "Grocery",
                "title": f"[{RETAILER_LABELS.get(best.retailer, best.retailer.upper())}] {grocery_item.ingredient_name} ({quantity_label(grocery_item)})",
                "notes": " • ".join(
                    part
                    for part in [best.product_name, best.package_size, best.availability, notes]
                    if part
                ),
                "metadata": {
                    "grocery_item_id": grocery_item.id,
                    "retailer": best.retailer,
                    "line_price": best.line_price,
                    "store_name": best.store_name,
                },
            }
        )

    matched_items.sort(
        key=lambda item: (
            RETAILER_SORT.get(str(item["metadata"]["retailer"]), 99),
            str(item["title"]),
        )
    )

    combined = matched_items + review_items
    for index, item in enumerate(combined):
        item["sort_order"] = index
        items.append(item)
    return items, warnings


def create_export_run(session: Session, week: Week, payload: ExportCreateRequest) -> dict[str, object]:
    refreshed_week = get_week(session, week.id)
    if refreshed_week is None:
        raise ValueError(f"Week {week.id} not found.")

    if payload.export_type == "shopping_split" and refreshed_week.status != "priced":
        raise ValueError("Shopping split exports require a priced week.")

    if payload.export_type == "meal_plan":
        export_items, warnings = build_meal_plan_export_items(refreshed_week)
    else:
        export_items, warnings = build_shopping_split_export_items(refreshed_week)

    export_run = ExportRun(
        week_id=refreshed_week.id,
        destination=payload.destination,
        export_type=payload.export_type,
        status="pending",
        item_count=len(export_items),
        payload_json=json.dumps(
            {
                "week_id": refreshed_week.id,
                "destination": payload.destination,
                "export_type": payload.export_type,
                "warnings": warnings,
            }
        ),
    )
    session.add(export_run)
    session.flush()

    for item in export_items:
        session.add(
            ExportItem(
                export_run_id=export_run.id,
                sort_order=item["sort_order"],
                list_name=item["list_name"],
                title=item["title"],
                notes=item["notes"],
                metadata_json=json.dumps(item["metadata"]),
            )
        )

    session.flush()
    session.refresh(export_run)
    return export_run_payload(export_run)


def complete_export_run(session: Session, export_run: ExportRun, payload: ExportCompleteRequest) -> dict[str, object]:
    export_run.status = payload.status
    export_run.error = payload.error
    export_run.external_ref = payload.external_ref
    export_run.completed_at = utcnow()

    item_status = "completed" if payload.status == "completed" else "failed"
    for item in export_run.items:
        item.status = item_status

    session.flush()
    return export_run_payload(export_run)


def apple_reminders_payload(export_run: ExportRun) -> dict[str, object]:
    created_at = export_run.created_at.astimezone(timezone.utc).isoformat() if export_run.created_at else ""
    ordered_items = sorted(export_run.items, key=lambda item: (item.list_name, item.sort_order, item.title))
    return {
        "export_id": export_run.id,
        "destination": export_run.destination,
        "export_type": export_run.export_type,
        "created_at": created_at,
        "items": [
            {
                "list_name": item.list_name,
                "title": item.title,
                "notes": item.notes,
                "sort_order": item.sort_order,
                "metadata": json.loads(item.metadata_json or "{}"),
            }
            for item in ordered_items
        ],
    }
