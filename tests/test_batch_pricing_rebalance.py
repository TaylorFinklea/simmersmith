"""pricing-rebalance lane — bug bash 2026-06-13 fixes.

#19 import_pricing committed a partial price write on a payload that fails
    validation (duplicate / unknown pair). It must validate the WHOLE payload
    UP FRONT and mutate nothing on a bad payload.
#2  _run_rebalance_day deleted the day's WeekMeal rows BEFORE the AI call, so a
    provider RuntimeError (returned as ok=False, not raised) let session_scope
    COMMIT the deletion = permanent meal loss. The delete must happen only
    AFTER run_rebalance() succeeds.
"""
from __future__ import annotations

from datetime import date

from app.config import get_settings
from app.db import session_scope
from app.models import GroceryItem, RetailerPrice, Week, new_id
from app.models.week import WeekMeal
from app.schemas import PricingImportRequest
from app.services.assistant_tools import run_tool
from app.services.pricing import import_pricing


# ── #19 — import_pricing validates the whole payload before mutating ──────


def _seed_priceable_week(session) -> tuple[str, str]:
    """Create an approved week with one grocery item that already has an
    existing aldi RetailerPrice. Returns (week_id, grocery_item_id)."""
    user_id = get_settings().local_user_id
    week = Week(
        id=new_id(),
        user_id=user_id,
        household_id=user_id,
        week_start=date(2026, 7, 6),
        week_end=date(2026, 7, 12),
        status="approved",
    )
    session.add(week)
    item = GroceryItem(
        id=new_id(),
        week_id=week.id,
        ingredient_name="ground turkey",
        normalized_name="ground turkey",
    )
    session.add(item)
    session.add(
        RetailerPrice(
            id=new_id(),
            grocery_item_id=item.id,
            retailer="aldi",
            status="matched",
            line_price=4.0,
        )
    )
    session.flush()
    return week.id, item.id


def test_import_pricing_duplicate_pair_leaves_existing_prices_untouched(client) -> None:
    with session_scope() as session:
        week_id, item_id = _seed_priceable_week(session)

    # Two rows for the SAME (item, walmart) pair, replace_existing=False so the
    # function would otherwise DELETE the existing aldi row mid-loop.
    payload = PricingImportRequest(
        replace_existing=False,
        items=[
            {"grocery_item_id": item_id, "retailer": "walmart", "line_price": 6.0},
            {"grocery_item_id": item_id, "retailer": "walmart", "line_price": 6.5},
        ],
    )

    with session_scope() as session:
        week = session.get(Week, week_id)
        raised = False
        try:
            import_pricing(session, week, payload)
        except ValueError as exc:
            raised = True
            assert "Duplicate" in str(exc)
    assert raised

    # Nothing was mutated: the pre-existing aldi price survives and no walmart
    # rows were written (pre-fix the per-pair DELETE/INSERT ran before the
    # duplicate check raised).
    with session_scope() as session:
        prices = (
            session.query(RetailerPrice)
            .filter(RetailerPrice.grocery_item_id == item_id)
            .all()
        )
        retailers = sorted(p.retailer for p in prices)
        assert retailers == ["aldi"]


def test_import_pricing_unknown_item_leaves_existing_prices_untouched(client) -> None:
    with session_scope() as session:
        week_id, item_id = _seed_priceable_week(session)

    payload = PricingImportRequest(
        replace_existing=False,
        items=[
            {"grocery_item_id": item_id, "retailer": "walmart", "line_price": 6.0},
            {"grocery_item_id": "does-not-exist", "retailer": "walmart", "line_price": 1.0},
        ],
    )

    with session_scope() as session:
        week = session.get(Week, week_id)
        raised = False
        try:
            import_pricing(session, week, payload)
        except ValueError as exc:
            raised = True
            assert "Unknown grocery item" in str(exc)
    assert raised

    with session_scope() as session:
        prices = (
            session.query(RetailerPrice)
            .filter(RetailerPrice.grocery_item_id == item_id)
            .all()
        )
        # Only the original aldi row remains — the valid walmart row was NOT
        # inserted because the whole payload is rejected up front.
        assert sorted(p.retailer for p in prices) == ["aldi"]


def test_import_pricing_valid_payload_still_imports(client) -> None:
    with session_scope() as session:
        week_id, item_id = _seed_priceable_week(session)

    payload = PricingImportRequest(
        replace_existing=False,
        items=[
            {
                "grocery_item_id": item_id,
                "retailer": "walmart",
                "status": "matched",
                "line_price": 6.0,
            }
        ],
    )

    with session_scope() as session:
        week = session.get(Week, week_id)
        result = import_pricing(session, week, payload)
        assert result["week_id"] == week_id

    with session_scope() as session:
        prices = (
            session.query(RetailerPrice)
            .filter(RetailerPrice.grocery_item_id == item_id)
            .all()
        )
        # aldi (existing) + walmart (newly imported) both present.
        assert sorted(p.retailer for p in prices) == ["aldi", "walmart"]


# ── #2 — rebalance_day failure must NOT delete the day's meals ────────────


def _seed_week_with_meal(client) -> tuple[str, date]:
    body = client.post("/api/weeks", json={"week_start": "2026-08-03"}).json()
    week_id = body["week_id"]
    target = date(2026, 8, 3)
    with session_scope() as session:
        session.add(
            WeekMeal(
                id=new_id(),
                week_id=week_id,
                day_name="Monday",
                meal_date=target,
                slot="dinner",
                recipe_name="Old Dinner",
                source="ai",
            )
        )
    return week_id, target


def test_rebalance_day_failure_preserves_existing_meals(client, monkeypatch) -> None:
    user_id = get_settings().local_user_id

    # A dietary goal is required before rebalancing.
    client.put(
        "/api/profile/dietary-goal",
        json={"goal_type": "maintain", "daily_calories": 2000, "protein_g": 150, "carbs_g": 200, "fat_g": 60},
    )
    week_id, target = _seed_week_with_meal(client)

    def _boom(**kwargs):
        raise RuntimeError("provider-503")

    monkeypatch.setattr("app.services.week_planner.rebalance_day", _boom)

    # Run through the assistant tool path, which commits on normal return
    # (session_scope). Pre-fix the deletion was flushed before the AI call and
    # this commit persisted a wiped day.
    with session_scope() as session:
        result = run_tool(
            "rebalance_day",
            session=session,
            user_id=user_id,
            household_id=user_id,
            linked_week_id=week_id,
            args={"meal_date": target.isoformat()},
            settings=get_settings(),
        )
    assert result.ok is False
    assert "provider-503" in result.detail

    # The Monday dinner must still be there.
    with session_scope() as session:
        meals = (
            session.query(WeekMeal)
            .filter(WeekMeal.week_id == week_id, WeekMeal.meal_date == target)
            .all()
        )
        assert [m.recipe_name for m in meals] == ["Old Dinner"]


def test_rebalance_day_success_replaces_the_day(client, monkeypatch) -> None:
    user_id = get_settings().local_user_id

    client.put(
        "/api/profile/dietary-goal",
        json={"goal_type": "maintain", "daily_calories": 2000, "protein_g": 150, "carbs_g": 200, "fat_g": 60},
    )
    week_id, target = _seed_week_with_meal(client)

    def _draft(**kwargs):
        day_name = kwargs["day_name"]
        return {
            "prompt": "replan",
            "model": "week-planner-rebalance",
            "recipes": [],
            "meal_plan": [
                {
                    "day_name": day_name,
                    "meal_date": target.isoformat(),
                    "slot": "dinner",
                    "recipe_name": "Rebalanced Dinner",
                    "ingredients": [],
                }
            ],
            "week_notes": "",
        }

    monkeypatch.setattr("app.services.week_planner.rebalance_day", _draft)

    with session_scope() as session:
        result = run_tool(
            "rebalance_day",
            session=session,
            user_id=user_id,
            household_id=user_id,
            linked_week_id=week_id,
            args={"meal_date": target.isoformat()},
            settings=get_settings(),
        )
    assert result.ok is True

    with session_scope() as session:
        meals = (
            session.query(WeekMeal)
            .filter(WeekMeal.week_id == week_id, WeekMeal.meal_date == target)
            .all()
        )
        names = [m.recipe_name for m in meals]
        assert "Old Dinner" not in names
        assert "Rebalanced Dinner" in names
