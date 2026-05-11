"""M22 Phase 1.6: tests for grocery list mutability + smart-merge regen.

Cases:
1. POST custom item → appears, regenerate preserves it.
2. PATCH quantity → quantity_override set, regen keeps it.
3. PATCH removed=true → tombstone, doesn't reappear after regen, hidden
   from week_payload.
4. PATCH removed=false → tombstone clears, item resurfaces.
5. Check item as user A → user B in same household sees it checked.
6. Check state survives smart-merge regenerate.
7. Add a meal that contributes a brand-new ingredient → smart merge
   adds without wiping any user-added items.
8. Remove a meal whose only ingredient was a generated item → that
   item is deleted UNLESS user had an override (then it stays with
   `review_flag = "no longer in any meal"`).
9. Auto-merge event toggle on → ingredients flow into week list;
   toggle off → those ingredients unmerge.
10. `GET /grocery?since=...` returns only updated items.
"""
from __future__ import annotations

import os
from datetime import date, datetime, timezone

import pytest
from fastapi.testclient import TestClient

from app.auth import issue_session_jwt
from app.config import get_settings
from app.db import session_scope
from app.main import app
from app.models import Event, GroceryItem, User, Week, WeekMeal
from app.models._base import new_id, utcnow
from app.schemas import DraftFromAIRequest, MealDraftPayload, RecipeIngredientPayload, RecipePayload
from app.services.drafts import apply_ai_draft
from app.services.events import create_event, add_event_meal
from app.services.drafts import upsert_profile_settings
from app.services.grocery import (
    add_user_grocery_item,
    auto_regenerate_grocery_for_week,
    regenerate_grocery_for_week,
    set_grocery_item_checked,
    update_grocery_item,
)
from app.services.households import claim_invitation, create_solo_household
from app.services.weeks import create_or_get_week, get_week
from sqlalchemy import select


USER_A_ID = "aaaaaaa1-1111-1111-1111-aaaaaaaaaaaa"
USER_B_ID = "bbbbbbb1-1111-1111-1111-bbbbbbbbbbbb"
TEST_JWT_SECRET = "test-grocery-secret-not-for-production"


@pytest.fixture(autouse=True)
def setup_auth_and_users():
    os.environ["SIMMERSMITH_JWT_SECRET"] = TEST_JWT_SECRET
    get_settings.cache_clear()

    with session_scope() as session:
        session.add(User(id=USER_A_ID, email="a@test.com", display_name="User A", created_at=utcnow()))
        session.add(User(id=USER_B_ID, email="b@test.com", display_name="User B", created_at=utcnow()))
        session.flush()
        create_solo_household(session, USER_A_ID)
        create_solo_household(session, USER_B_ID)

    yield

    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    get_settings.cache_clear()


@pytest.fixture
def client() -> TestClient:
    with TestClient(app) as c:
        yield c


def _headers(user_id: str) -> dict[str, str]:
    settings = get_settings()
    return {"Authorization": f"Bearer {issue_session_jwt(user_id, settings)}"}


def _household_id_for(user_id: str) -> str:
    from app.services.households import get_household_id

    with session_scope() as session:
        return get_household_id(session, user_id)


def _seed_week_with_recipe(*, user_id: str, household_id: str, recipe_id: str, ingredient_name: str, quantity: float, unit: str) -> Week:
    """Create a Week containing a single recipe with one ingredient.
    Returns the persisted Week (refreshed)."""
    week_start = date(2026, 5, 4)
    with session_scope() as session:
        week = create_or_get_week(
            session, user_id=user_id, household_id=household_id, week_start=week_start, notes=""
        )
        payload = DraftFromAIRequest(
            prompt="seed",
            recipes=[
                RecipePayload(
                    recipe_id=recipe_id,
                    name=recipe_id.replace("-", " ").title(),
                    meal_type="dinner",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(
                            ingredient_name=ingredient_name, quantity=quantity, unit=unit
                        ),
                    ],
                ),
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=week_start,
                    slot="dinner",
                    recipe_id=recipe_id,
                    recipe_name=recipe_id.replace("-", " ").title(),
                    servings=4,
                ),
            ],
        )
        apply_ai_draft(session, week, payload)
        regenerate_grocery_for_week(session, user_id, household_id, week)
        return get_week(session, household_id, week.id)


def _grocery_items(week_id: str, household_id: str) -> list[GroceryItem]:
    with session_scope() as session:
        week = get_week(session, household_id, week_id)
        # Force lazy-load by touching the relationship
        return list(week.grocery_items) if week else []


# ---------------------------------------------------------------------
# Case 1: POST custom item, smart-merge preserves it
# ---------------------------------------------------------------------

def test_user_added_item_survives_regenerate(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="seed-recipe",
        ingredient_name="Carrots",
        quantity=2,
        unit="lb",
    )
    week_id = week.id

    # Add a paper-towel via API.
    resp = client.post(
        f"/api/weeks/{week_id}/grocery/items",
        json={"name": "Paper towels", "quantity": 1, "unit": "pkg"},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["is_user_added"] is True
    assert body["ingredient_name"] == "Paper towels"

    # Regenerate — paper towels must survive.
    client.post(f"/api/weeks/{week_id}/grocery/regenerate", headers=_headers(USER_A_ID))

    items = _grocery_items(week_id, household_id)
    names = {item.ingredient_name for item in items}
    assert "Paper towels" in names
    assert "Carrots" in names


# ---------------------------------------------------------------------
# Case 2: PATCH quantity sets quantity_override, survives regen
# ---------------------------------------------------------------------

def test_quantity_override_survives_regenerate(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="bread",
        ingredient_name="Flour",
        quantity=2,
        unit="cup",
    )
    week_id = week.id
    item = next(item for item in week.grocery_items if item.ingredient_name == "Flour")

    # Override 2 cups → 5 cups.
    resp = client.patch(
        f"/api/weeks/{week_id}/grocery/items/{item.id}",
        json={"quantity": 5},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["quantity_override"] == 5
    assert body["total_quantity"] == 2.0  # auto stays put

    # Regenerate.
    client.post(f"/api/weeks/{week_id}/grocery/regenerate", headers=_headers(USER_A_ID))

    items = _grocery_items(week_id, household_id)
    flour = next(i for i in items if i.ingredient_name == "Flour")
    assert flour.quantity_override == 5.0
    assert flour.total_quantity == 2.0


# ---------------------------------------------------------------------
# Case 3: PATCH removed=true → tombstone, hidden from week_payload
# ---------------------------------------------------------------------

def test_user_removed_tombstone_persists_and_hides(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="omelette",
        ingredient_name="Eggs",
        quantity=4,
        unit="ea",
    )
    week_id = week.id
    item_id = next(item.id for item in week.grocery_items if item.ingredient_name == "Eggs")

    resp = client.patch(
        f"/api/weeks/{week_id}/grocery/items/{item_id}",
        json={"removed": True},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["is_user_removed"] is True

    # week_payload via GET /weeks/{id} excludes removed items.
    week_resp = client.get(f"/api/weeks/{week_id}", headers=_headers(USER_A_ID))
    assert week_resp.status_code == 200
    visible = {row["ingredient_name"] for row in week_resp.json().get("grocery_items", [])}
    assert "Eggs" not in visible

    # Regenerate — tombstone keeps Eggs out of the visible list.
    client.post(f"/api/weeks/{week_id}/grocery/regenerate", headers=_headers(USER_A_ID))
    week_resp = client.get(f"/api/weeks/{week_id}", headers=_headers(USER_A_ID))
    visible = {row["ingredient_name"] for row in week_resp.json().get("grocery_items", [])}
    assert "Eggs" not in visible

    # The tombstone row still exists in the DB though.
    items = _grocery_items(week_id, household_id)
    eggs = next(i for i in items if i.ingredient_name == "Eggs")
    assert eggs.is_user_removed is True


# ---------------------------------------------------------------------
# Case 4: removed=false un-tombstones
# ---------------------------------------------------------------------

def test_user_removed_can_be_undone(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="pancakes",
        ingredient_name="Milk",
        quantity=1,
        unit="cup",
    )
    week_id = week.id
    item_id = next(i.id for i in week.grocery_items if i.ingredient_name == "Milk")

    client.patch(
        f"/api/weeks/{week_id}/grocery/items/{item_id}",
        json={"removed": True},
        headers=_headers(USER_A_ID),
    )
    client.patch(
        f"/api/weeks/{week_id}/grocery/items/{item_id}",
        json={"removed": False},
        headers=_headers(USER_A_ID),
    )
    week_resp = client.get(f"/api/weeks/{week_id}", headers=_headers(USER_A_ID))
    visible = {row["ingredient_name"] for row in week_resp.json().get("grocery_items", [])}
    assert "Milk" in visible


# ---------------------------------------------------------------------
# Case 5: check state is household-shared (A checks → B sees it)
# ---------------------------------------------------------------------

def test_check_state_is_household_shared(client: TestClient) -> None:
    # B joins A's household via invitation.
    invite_resp = client.post("/api/household/invitations", headers=_headers(USER_A_ID))
    code = invite_resp.json()["code"]
    join_resp = client.post(
        "/api/household/join", json={"code": code}, headers=_headers(USER_B_ID)
    )
    assert join_resp.status_code == 200, join_resp.text

    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="salad",
        ingredient_name="Lettuce",
        quantity=1,
        unit="ea",
    )
    week_id = week.id
    item_id = next(i.id for i in week.grocery_items if i.ingredient_name == "Lettuce")

    # A checks the item.
    resp = client.post(
        f"/api/weeks/{week_id}/grocery/items/{item_id}/check",
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["is_checked"] is True
    assert resp.json()["checked_by_user_id"] == USER_A_ID

    # B sees it as checked.
    week_resp = client.get(f"/api/weeks/{week_id}", headers=_headers(USER_B_ID))
    assert week_resp.status_code == 200
    grocery = week_resp.json().get("grocery_items", [])
    lettuce = next(g for g in grocery if g["ingredient_name"] == "Lettuce")
    assert lettuce["is_checked"] is True
    assert lettuce["checked_by_user_id"] == USER_A_ID


# ---------------------------------------------------------------------
# Case 6: check state survives smart-merge regenerate
# ---------------------------------------------------------------------

def test_check_state_survives_regenerate(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="rice-bowl",
        ingredient_name="Rice",
        quantity=2,
        unit="cup",
    )
    week_id = week.id
    item_id = next(i.id for i in week.grocery_items if i.ingredient_name == "Rice")

    client.post(
        f"/api/weeks/{week_id}/grocery/items/{item_id}/check",
        headers=_headers(USER_A_ID),
    )
    client.post(f"/api/weeks/{week_id}/grocery/regenerate", headers=_headers(USER_A_ID))

    items = _grocery_items(week_id, household_id)
    rice = next(i for i in items if i.ingredient_name == "Rice")
    assert rice.is_checked is True
    assert rice.checked_by_user_id == USER_A_ID


# ---------------------------------------------------------------------
# Case 7: New meal contributes new ingredient; user-added items survive
# ---------------------------------------------------------------------

def test_smart_merge_adds_new_ingredient_preserves_user_added(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="taco-bowl",
        ingredient_name="Black beans",
        quantity=1,
        unit="can",
    )
    week_id = week.id

    # User adds paper towels.
    client.post(
        f"/api/weeks/{week_id}/grocery/items",
        json={"name": "Paper towels", "unit": "pkg"},
        headers=_headers(USER_A_ID),
    )

    # Append a second meal directly without replacing the existing
    # meal plan (`apply_ai_draft` would wipe + rebuild the WeekMeals).
    from app.models import Recipe, RecipeIngredient

    week_start = week.week_start
    with session_scope() as session:
        recipe = Recipe(
            id="pasta-night",
            user_id=USER_A_ID,
            household_id=household_id,
            name="Pasta Night",
            meal_type="dinner",
            servings=4,
        )
        session.add(recipe)
        session.add(
            RecipeIngredient(
                id="pasta-night-spaghetti",
                recipe_id="pasta-night",
                ingredient_name="Spaghetti",
                normalized_name="spaghetti",
                quantity=1,
                unit="pkg",
            )
        )
        session.flush()
        live_week = get_week(session, household_id, week_id)
        live_week.meals.append(
            WeekMeal(
                week_id=week_id,
                day_name="Tuesday",
                meal_date=week_start,
                slot="dinner",
                recipe_id="pasta-night",
                recipe_name="Pasta Night",
                servings=4,
            )
        )
        session.flush()
        regenerate_grocery_for_week(session, USER_A_ID, household_id, live_week)

    items = _grocery_items(week_id, household_id)
    names = {i.ingredient_name.lower() for i in items}
    assert "paper towels" in names
    assert "spaghetti" in names
    assert "black beans" in names


# ---------------------------------------------------------------------
# Case 8: Removing the only meal that contributed an item → row deleted
# unless user had an override
# ---------------------------------------------------------------------

def test_meal_removal_drops_auto_item_keeps_overridden(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="curry",
        ingredient_name="Coconut milk",
        quantity=1,
        unit="can",
    )
    week_id = week.id
    coconut_id = next(i.id for i in week.grocery_items if i.ingredient_name == "Coconut milk")

    # Override the quantity so we know the row should survive.
    client.patch(
        f"/api/weeks/{week_id}/grocery/items/{coconut_id}",
        json={"quantity": 2},
        headers=_headers(USER_A_ID),
    )

    # Remove all meals from the week.
    with session_scope() as session:
        live_week = get_week(session, household_id, week_id)
        for meal in list(live_week.meals):
            session.delete(meal)
        session.flush()
        regenerate_grocery_for_week(session, USER_A_ID, household_id, live_week)

    items = _grocery_items(week_id, household_id)
    # Coconut milk stays because the user invested an override.
    coconut = next((i for i in items if i.ingredient_name == "Coconut milk"), None)
    assert coconut is not None
    assert coconut.review_flag == "no longer in any meal"


def test_meal_removal_drops_pure_auto_item(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="taco",
        ingredient_name="Tortillas",
        quantity=8,
        unit="ea",
    )
    week_id = week.id

    with session_scope() as session:
        live_week = get_week(session, household_id, week_id)
        for meal in list(live_week.meals):
            session.delete(meal)
        session.flush()
        regenerate_grocery_for_week(session, USER_A_ID, household_id, live_week)

    items = _grocery_items(week_id, household_id)
    assert all(i.ingredient_name != "Tortillas" for i in items)


# ---------------------------------------------------------------------
# Case 9: auto_merge_grocery toggle merges/unmerges event ingredients
# ---------------------------------------------------------------------

def test_event_merge_uses_event_quantity_column(client: TestClient) -> None:
    """M22.2: a merged event contributes via `event_quantity`, not by
    bumping `total_quantity`. Smart-merge regen of the week then can
    refresh `total_quantity` (week-meal portion) without disturbing
    the event delta.
    """
    household_id = _household_id_for(USER_A_ID)
    # Week with a meal that uses Cake flour 2 cups (week portion)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="bread-loaf",
        ingredient_name="Cake flour",
        quantity=2,
        unit="cup",
    )
    week_id = week.id
    week_start = week.week_start

    with session_scope() as session:
        event = create_event(
            session, user_id=USER_A_ID, household_id=household_id,
            name="Birthday", event_date=week_start, occasion="birthday",
            attendee_count=4, notes="", attendees=[],
        )
        session.flush()
        event_id = event.id
        from app.models import EventMealIngredient
        meal = add_event_meal(
            session, event, role="main", recipe_id=None,
            recipe_name="Birthday Cake", servings=4, notes="",
            assigned_guest_id=None, household_id=household_id,
        )
        session.flush()
        session.add(EventMealIngredient(
            id=f"{meal.id}-cf", event_meal_id=meal.id,
            ingredient_name="Cake flour", normalized_name="cake flour",
            quantity=3, unit="cup",
        ))

    # Merge the event into the week.
    resp = client.post(
        f"/api/events/{event_id}/grocery/refresh",
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text

    items = _grocery_items(week_id, household_id)
    flour = next(i for i in items if i.ingredient_name.lower() == "cake flour")
    # Week meal contributed 2 cups → total_quantity stays at 2.
    assert flour.total_quantity == 2.0
    # Event added 3 cups → event_quantity holds those 3.
    assert flour.event_quantity == 3.0

    # Smart-merge regen does NOT disturb event_quantity.
    client.post(f"/api/weeks/{week_id}/grocery/regenerate", headers=_headers(USER_A_ID))
    items = _grocery_items(week_id, household_id)
    flour = next(i for i in items if i.ingredient_name.lower() == "cake flour")
    assert flour.total_quantity == 2.0
    assert flour.event_quantity == 3.0

    # Toggle auto-merge off → unmerge subtracts the 3 cups; the row
    # stays because the 2-cup week portion remains.
    resp = client.patch(
        f"/api/events/{event_id}",
        json={"auto_merge_grocery": False},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    items = _grocery_items(week_id, household_id)
    flour = next((i for i in items if i.ingredient_name.lower() == "cake flour"), None)
    assert flour is not None
    assert flour.total_quantity == 2.0
    assert flour.event_quantity is None


def test_event_auto_merge_toggle_merges_and_unmerges(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    # Week first
    week_start = date(2026, 5, 4)
    with session_scope() as session:
        week = create_or_get_week(
            session, user_id=USER_A_ID, household_id=household_id, week_start=week_start, notes=""
        )
        week_id = week.id

    # Event in that week, with a meal that has an inline ingredient.
    with session_scope() as session:
        event = create_event(
            session,
            user_id=USER_A_ID,
            household_id=household_id,
            name="Birthday Dinner",
            event_date=week_start,
            occasion="birthday",
            attendee_count=4,
            notes="",
            attendees=[],
        )
        session.flush()
        event_id = event.id
        add_event_meal(
            session,
            event,
            role="main",
            recipe_id=None,
            recipe_name="Birthday Cake",
            servings=4,
            notes="",
            assigned_guest_id=None,
            household_id=household_id,
        )
        session.commit()

    # Manually attach an inline ingredient to the event meal so the
    # event grocery aggregation has something to fold.
    with session_scope() as session:
        from app.models import EventMealIngredient

        ev = session.scalar(select(Event).where(Event.id == event_id))
        meal = ev.meals[0]
        ing = EventMealIngredient(
            id=f"{meal.id}-cake-flour",
            event_meal_id=meal.id,
            ingredient_name="Cake flour",
            normalized_name="cake flour",
            quantity=3,
            unit="cup",
        )
        session.add(ing)
        session.commit()

    # Refresh the event grocery list with auto_merge ON (default).
    resp = client.post(
        f"/api/events/{event_id}/grocery/refresh",
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text

    week_items_after_merge = {
        i.ingredient_name for i in _grocery_items(week_id, household_id)
    }
    assert "Cake flour" in week_items_after_merge

    # Toggle auto-merge OFF — week should drop cake flour again.
    resp = client.patch(
        f"/api/events/{event_id}",
        json={"auto_merge_grocery": False},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text

    week_items_after_unmerge = {
        i.ingredient_name for i in _grocery_items(week_id, household_id)
    }
    assert "Cake flour" not in week_items_after_unmerge


# ---------------------------------------------------------------------
# Case 10: GET /grocery?since= returns delta only
# ---------------------------------------------------------------------

def test_grocery_delta_endpoint_returns_only_changed_items(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="snack-prep",
        ingredient_name="Almonds",
        quantity=1,
        unit="cup",
    )
    week_id = week.id
    item = next(
        i for i in week.grocery_items if i.normalized_name.lower() == "almonds"
    )

    cursor = datetime.now(timezone.utc).isoformat()

    client.post(
        f"/api/weeks/{week_id}/grocery/items/{item.id}/check",
        headers=_headers(USER_A_ID),
    )

    resp = client.get(
        f"/api/weeks/{week_id}/grocery",
        params={"since": cursor},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    item_ids = {i["grocery_item_id"] for i in body["items"]}
    assert item.id in item_ids
    # Only the mutated item shows up — the seeded row's `updated_at`
    # predates the cursor.
    assert len(body["items"]) == 1
    assert body["server_time"] is not None


# ---------------------------------------------------------------------
# Build 87: auto-grocery gating + plan-shopping + clear-auto + store_label
# ---------------------------------------------------------------------

def test_auto_grocery_defaults_off_meal_add_does_not_populate_grocery(client: TestClient) -> None:
    """The new build-87 default is OFF — adding meals must NOT auto-add
    grocery rows. The plan-shopping flow is the user's path now.
    """
    household_id = _household_id_for(USER_A_ID)
    week_start = date(2026, 5, 4)
    with session_scope() as session:
        week = create_or_get_week(
            session, user_id=USER_A_ID, household_id=household_id, week_start=week_start, notes=""
        )
        # Drive the gated path directly so the unit test isn't tangled
        # in the full /api/weeks/draft-from-ai flow.
        payload = DraftFromAIRequest(
            prompt="seed",
            recipes=[
                RecipePayload(
                    recipe_id="seed",
                    name="Seed",
                    meal_type="dinner",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(
                            ingredient_name="Cabbage", quantity=1, unit="head"
                        ),
                    ],
                ),
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=week_start,
                    slot="dinner",
                    recipe_id="seed",
                    recipe_name="Seed",
                    servings=4,
                ),
            ],
        )
        apply_ai_draft(session, week, payload)
        # The wrapper used by drafts.py / sides.py
        auto_regenerate_grocery_for_week(session, USER_A_ID, household_id, week)
        week_id = week.id

    items = _grocery_items(week_id, household_id)
    assert items == []


def test_auto_grocery_when_enabled_populates_via_wrapper(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    with session_scope() as session:
        upsert_profile_settings(session, USER_A_ID, {"auto_grocery_from_meals": "1"})

    week_start = date(2026, 5, 11)
    with session_scope() as session:
        week = create_or_get_week(
            session, user_id=USER_A_ID, household_id=household_id, week_start=week_start, notes=""
        )
        payload = DraftFromAIRequest(
            prompt="seed",
            recipes=[
                RecipePayload(
                    recipe_id="seed-2",
                    name="Seed Two",
                    meal_type="dinner",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(
                            ingredient_name="Onion", quantity=2, unit="ea"
                        ),
                    ],
                ),
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=week_start,
                    slot="dinner",
                    recipe_id="seed-2",
                    recipe_name="Seed Two",
                    servings=4,
                ),
            ],
        )
        apply_ai_draft(session, week, payload)
        auto_regenerate_grocery_for_week(session, USER_A_ID, household_id, week)
        week_id = week.id

    items = _grocery_items(week_id, household_id)
    names = {item.ingredient_name for item in items}
    assert "Onion" in names


def test_plan_shopping_endpoint_excludes_items_already_on_grocery_list(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="plan-shop",
        ingredient_name="Garlic",
        quantity=4,
        unit="clove",
    )
    week_id = week.id

    # Right after seed, all the meal's ingredients are on the grocery list.
    resp = client.get(
        f"/api/weeks/{week_id}/grocery/plan-shopping", headers=_headers(USER_A_ID)
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    plan_names = {row["ingredient_name"] for row in body["items"]}
    assert "Garlic" not in plan_names, "already on grocery list, should not appear in plan"

    # Soft-delete the row — plan should NOT re-suggest it (the user
    # deliberately removed it).
    item = next(item for item in _grocery_items(week_id, household_id) if item.ingredient_name == "Garlic")
    client.patch(
        f"/api/weeks/{week_id}/grocery/items/{item.id}",
        json={"removed": True},
        headers=_headers(USER_A_ID),
    )
    resp = client.get(
        f"/api/weeks/{week_id}/grocery/plan-shopping", headers=_headers(USER_A_ID)
    )
    body = resp.json()
    plan_names = {row["ingredient_name"] for row in body["items"]}
    assert "Garlic" not in plan_names, "tombstoned items must not reappear in plan-shopping"


def test_quick_add_persists_store_label_and_normalized_name(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="qa",
        ingredient_name="Tomatoes",
        quantity=3,
        unit="ea",
    )
    week_id = week.id

    resp = client.post(
        f"/api/weeks/{week_id}/grocery/items/quick-add",
        json={
            "name": "Basil",
            "normalized_name": "basil",
            "quantity": 1,
            "quantity_text": "",
            "unit": "bunch",
            "category": "produce",
            "store_label": "Kroger",
        },
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["ingredient_name"] == "Basil"
    assert body["normalized_name"] == "basil"
    assert body["store_label"] == "Kroger"
    assert body["is_user_added"] is True


def test_clear_auto_deletes_auto_rows_but_keeps_user_added(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="clear-test",
        ingredient_name="Lettuce",
        quantity=1,
        unit="head",
    )
    week_id = week.id

    # User-added row that must survive
    resp = client.post(
        f"/api/weeks/{week_id}/grocery/items",
        json={"name": "Paper Towels", "quantity": 1, "unit": "pkg"},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200

    resp = client.post(
        f"/api/weeks/{week_id}/grocery/clear-auto", headers=_headers(USER_A_ID)
    )
    assert resp.status_code == 200, resp.text

    items = _grocery_items(week_id, household_id)
    names = {item.ingredient_name for item in items}
    assert "Lettuce" not in names, "auto row must be cleared"
    assert "Paper Towels" in names, "user-added row must survive clear-auto"


def test_patch_store_label_round_trips(client: TestClient) -> None:
    household_id = _household_id_for(USER_A_ID)
    week = _seed_week_with_recipe(
        user_id=USER_A_ID,
        household_id=household_id,
        recipe_id="store-test",
        ingredient_name="Bread",
        quantity=1,
        unit="loaf",
    )
    week_id = week.id
    item = next(item for item in week.grocery_items if item.ingredient_name == "Bread")

    resp = client.patch(
        f"/api/weeks/{week_id}/grocery/items/{item.id}",
        json={"store_label": "Aldi"},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["store_label"] == "Aldi"

    # Clearing — pass empty string.
    resp = client.patch(
        f"/api/weeks/{week_id}/grocery/items/{item.id}",
        json={"store_label": ""},
        headers=_headers(USER_A_ID),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["store_label"] == ""
