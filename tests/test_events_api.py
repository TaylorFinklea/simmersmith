"""M10 Phase 1 regression tests — Guest + Event CRUD with ownership
isolation."""
from __future__ import annotations


def test_guest_crud_roundtrip(client) -> None:
    # Create
    resp = client.post(
        "/api/guests",
        json={
            "name": "Aunt Sue",
            "relationship_label": "Aunt",
            "dietary_notes": "prefers light food",
            "allergies": "gluten",
        },
    )
    assert resp.status_code == 200, resp.text
    sue = resp.json()
    assert sue["guest_id"]
    assert sue["name"] == "Aunt Sue"
    assert sue["allergies"] == "gluten"

    # List
    listing = client.get("/api/guests").json()
    assert any(g["guest_id"] == sue["guest_id"] for g in listing)

    # Update via same POST (upsert by guest_id)
    resp = client.post(
        "/api/guests",
        json={
            "guest_id": sue["guest_id"],
            "name": "Aunt Susan",
            "allergies": "gluten, dairy",
        },
    )
    assert resp.status_code == 200
    updated = resp.json()
    assert updated["name"] == "Aunt Susan"
    assert updated["allergies"] == "gluten, dairy"

    # Delete
    resp = client.delete(f"/api/guests/{sue['guest_id']}")
    assert resp.status_code == 204
    assert all(g["guest_id"] != sue["guest_id"] for g in client.get("/api/guests").json())


def test_event_create_with_attendees_and_readback(client) -> None:
    # Seed two guests
    sue = client.post(
        "/api/guests",
        json={"name": "Aunt Sue", "allergies": "gluten"},
    ).json()
    leo = client.post(
        "/api/guests",
        json={"name": "Nephew Leo", "dietary_notes": "no mushrooms"},
    ).json()

    resp = client.post(
        "/api/events",
        json={
            "name": "Easter Dinner",
            "event_date": "2026-04-26",
            "occasion": "holiday",
            "attendee_count": 10,
            "notes": "traditional ham",
            "attendees": [
                {"guest_id": sue["guest_id"], "plus_ones": 0},
                {"guest_id": leo["guest_id"], "plus_ones": 2},
            ],
        },
    )
    assert resp.status_code == 200, resp.text
    event = resp.json()
    assert event["name"] == "Easter Dinner"
    assert event["attendee_count"] == 10
    assert event["occasion"] == "holiday"
    assert {a["guest_id"] for a in event["attendees"]} == {sue["guest_id"], leo["guest_id"]}
    assert next(a["plus_ones"] for a in event["attendees"] if a["guest_id"] == leo["guest_id"]) == 2
    assert event["meals"] == []
    assert event["grocery_items"] == []

    # Summary list only carries counts, not nested attendees.
    summaries = client.get("/api/events").json()
    assert len(summaries) == 1
    assert summaries[0]["event_id"] == event["event_id"]
    assert summaries[0]["meal_count"] == 0


def test_event_update_replaces_attendees(client) -> None:
    a = client.post("/api/guests", json={"name": "Alice"}).json()
    b = client.post("/api/guests", json={"name": "Bob"}).json()

    event = client.post(
        "/api/events",
        json={
            "name": "Dinner party",
            "attendee_count": 4,
            "attendees": [{"guest_id": a["guest_id"], "plus_ones": 0}],
        },
    ).json()

    # Replace attendees wholesale
    resp = client.patch(
        f"/api/events/{event['event_id']}",
        json={"attendees": [{"guest_id": b["guest_id"], "plus_ones": 1}]},
    )
    assert resp.status_code == 200
    updated = resp.json()
    assert {a["guest_id"] for a in updated["attendees"]} == {b["guest_id"]}
    assert updated["attendees"][0]["plus_ones"] == 1


def test_event_delete(client) -> None:
    event = client.post(
        "/api/events",
        json={"name": "Quick party", "attendee_count": 2},
    ).json()

    resp = client.delete(f"/api/events/{event['event_id']}")
    assert resp.status_code == 204
    assert client.get(f"/api/events/{event['event_id']}").status_code == 404


def test_event_404_for_unknown_id(client) -> None:
    assert client.get("/api/events/does-not-exist").status_code == 404
    assert client.patch("/api/events/does-not-exist", json={}).status_code == 404
    assert client.delete("/api/events/does-not-exist").status_code == 404


def test_generate_event_menu_persists_meals_and_coverage(client, monkeypatch) -> None:
    """M10 Phase 2: POST /api/events/{id}/ai/menu triggers menu generation.
    We stub run_direct_provider so no network calls happen and we can
    verify the meal dicts land + coverage is mapped back to guest ids.
    """
    import json as _json

    sue = client.post(
        "/api/guests",
        json={"name": "Aunt Sue", "allergies": "gluten"},
    ).json()
    leo = client.post(
        "/api/guests",
        json={"name": "Nephew Leo", "dietary_notes": "no mushrooms"},
    ).json()

    event = client.post(
        "/api/events",
        json={
            "name": "Easter Dinner",
            "event_date": "2026-04-26",
            "occasion": "holiday",
            "attendee_count": 8,
            "attendees": [
                {"guest_id": sue["guest_id"]},
                {"guest_id": leo["guest_id"]},
            ],
        },
    ).json()

    fake_response = _json.dumps({
        "menu": [
            {
                "role": "starter",
                "recipe_name": "Deviled eggs",
                "servings": 8,
                "notes": "",
                "compatible_guests": ["Aunt Sue", "Nephew Leo"],
                "ingredients": [
                    {"ingredient_name": "eggs", "quantity": 12, "unit": "ea"},
                ],
            },
            {
                "role": "main",
                "recipe_name": "Honey-baked ham",
                "servings": 8,
                "notes": "Everyone except Sue (wheat glaze)",
                "compatible_guests": ["Nephew Leo"],
                "ingredients": [
                    {"ingredient_name": "ham", "quantity": 6, "unit": "lb"},
                ],
            },
            {
                "role": "main",
                "recipe_name": "Roasted salmon (GF)",
                "servings": 4,
                "notes": "GF-friendly",
                "compatible_guests": ["Aunt Sue", "Nephew Leo"],
                "ingredients": [
                    {"ingredient_name": "salmon", "quantity": 2, "unit": "lb"},
                ],
            },
        ],
        "coverage_summary": "Sue has the salmon + deviled eggs; Leo has both mains + eggs."
    })

    def fake_run_direct_provider(*, target, settings, user_settings, prompt):  # noqa: ARG001
        # Make sure guest context made it into the prompt.
        assert "Aunt Sue" in prompt
        assert "gluten" in prompt
        return fake_response

    def fake_availability(name, *, settings, user_settings):  # noqa: ARG001
        return (True, "env") if name == "openai" else (False, "unset")

    monkeypatch.setattr("app.services.event_ai.run_direct_provider", fake_run_direct_provider)
    monkeypatch.setattr("app.services.event_ai.direct_provider_availability", fake_availability)
    monkeypatch.setattr(
        "app.services.event_ai.resolve_direct_model",
        lambda name, *, settings, user_settings: "gpt-test",  # noqa: ARG005
    )

    resp = client.post(
        f"/api/events/{event['event_id']}/ai/menu",
        json={"prompt": "traditional with a GF option"},
    )
    assert resp.status_code == 200, resp.text
    payload = resp.json()
    assert "Sue" in payload["coverage_summary"]
    meals = payload["event"]["meals"]
    assert [m["recipe_name"] for m in meals] == [
        "Deviled eggs",
        "Honey-baked ham",
        "Roasted salmon (GF)",
    ]
    salmon = next(m for m in meals if m["recipe_name"] == "Roasted salmon (GF)")
    assert sue["guest_id"] in salmon["constraint_coverage"]
    assert leo["guest_id"] in salmon["constraint_coverage"]
    # Ham is compatible with Leo only (Sue excluded due to gluten glaze).
    ham = next(m for m in meals if m["recipe_name"] == "Honey-baked ham")
    assert sue["guest_id"] not in ham["constraint_coverage"]
    assert leo["guest_id"] in ham["constraint_coverage"]
    # Grocery was auto-regenerated after menu — should have at least the
    # three proteins/items we added.
    grocery = payload["event"]["grocery_items"]
    assert len(grocery) >= 3
    names = {g["ingredient_name"].lower() for g in grocery}
    assert any("ham" in n for n in names)
    assert any("salmon" in n for n in names)
    assert any("egg" in n for n in names)


def test_manual_event_meal_crud_with_assignee(client) -> None:
    """Manually add a dish with an assignee, edit it, delete it."""
    kirsten = client.post("/api/guests", json={"name": "Kirsten"}).json()
    event = client.post(
        "/api/events",
        json={
            "name": "Potluck",
            "attendee_count": 6,
            "attendees": [{"guest_id": kirsten["guest_id"]}],
        },
    ).json()
    event_id = event["event_id"]

    # Add
    resp = client.post(
        f"/api/events/{event_id}/meals",
        json={
            "role": "side",
            "recipe_name": "Kale Caesar salad",
            "servings": 8,
            "assigned_guest_id": kirsten["guest_id"],
            "notes": "Kirsten's signature",
        },
    )
    assert resp.status_code == 200, resp.text
    added = resp.json()
    assert len(added["meals"]) == 1
    meal = added["meals"][0]
    assert meal["recipe_name"] == "Kale Caesar salad"
    assert meal["assigned_guest_id"] == kirsten["guest_id"]
    assert meal["ai_generated"] is False
    meal_id = meal["meal_id"]

    # Edit
    resp = client.patch(
        f"/api/events/{event_id}/meals/{meal_id}",
        json={"servings": 10, "notes": "Kirsten's signature (double batch)"},
    )
    assert resp.status_code == 200
    edited = resp.json()["meals"][0]
    assert edited["servings"] == 10
    assert "double batch" in edited["notes"]

    # Clear assignee
    resp = client.patch(
        f"/api/events/{event_id}/meals/{meal_id}",
        json={"clear_assignee": True},
    )
    assert resp.status_code == 200
    assert resp.json()["meals"][0]["assigned_guest_id"] is None

    # Delete
    resp = client.delete(f"/api/events/{event_id}/meals/{meal_id}")
    assert resp.status_code == 200
    assert resp.json()["meals"] == []


def test_ai_menu_regeneration_preserves_manual_dishes(client, monkeypatch) -> None:
    """Pre-assigned manual dishes stay, AI dishes regenerate around them."""
    import json as _json

    kirsten = client.post("/api/guests", json={"name": "Kirsten"}).json()
    event = client.post(
        "/api/events",
        json={
            "name": "Potluck",
            "attendee_count": 6,
            "attendees": [{"guest_id": kirsten["guest_id"]}],
        },
    ).json()
    event_id = event["event_id"]

    # Manual dish
    client.post(
        f"/api/events/{event_id}/meals",
        json={
            "role": "side",
            "recipe_name": "Kirsten's salad",
            "assigned_guest_id": kirsten["guest_id"],
        },
    )

    def fake_run_direct_provider(*, target, settings, user_settings, prompt):  # noqa: ARG001
        # Preassigned dish should appear in the prompt.
        assert "Kirsten's salad" in prompt
        assert "being brought by Kirsten" in prompt
        return _json.dumps({
            "menu": [
                {"role": "main", "recipe_name": "Roast chicken", "servings": 6, "ingredients": []},
                {"role": "dessert", "recipe_name": "Pie", "servings": 6, "ingredients": []},
            ],
            "coverage_summary": "",
        })

    def fake_availability(name, *, settings, user_settings):  # noqa: ARG001
        return (True, "env") if name == "openai" else (False, "unset")

    monkeypatch.setattr("app.services.event_ai.run_direct_provider", fake_run_direct_provider)
    monkeypatch.setattr("app.services.event_ai.direct_provider_availability", fake_availability)
    monkeypatch.setattr(
        "app.services.event_ai.resolve_direct_model",
        lambda name, *, settings, user_settings: "gpt-test",  # noqa: ARG005
    )

    resp = client.post(
        f"/api/events/{event_id}/ai/menu",
        json={"prompt": ""},
    )
    assert resp.status_code == 200, resp.text
    meals = resp.json()["event"]["meals"]
    names = {m["recipe_name"] for m in meals}
    assert "Kirsten's salad" in names  # manual preserved
    assert "Roast chicken" in names  # AI added
    assert "Pie" in names
    # Kirsten's dish still attributed
    salad = next(m for m in meals if m["recipe_name"] == "Kirsten's salad")
    assert salad["assigned_guest_id"] == kirsten["guest_id"]
    assert salad["ai_generated"] is False


def test_assigned_meals_excluded_from_event_grocery(client) -> None:
    """M10.1 Phase 1: dishes assigned to a guest don't appear on the
    host's grocery list. The host is not shopping for ingredients the
    guest is bringing.
    """
    from app.db import session_scope
    from app.models import Event, EventMeal, EventMealIngredient, Guest

    # Seed a guest + an event with two manual dishes, one assigned.
    kirsten = client.post("/api/guests", json={"name": "Kirsten"}).json()
    event_resp = client.post(
        "/api/events",
        json={
            "name": "Potluck",
            "attendee_count": 6,
            "attendees": [{"guest_id": kirsten["guest_id"]}],
        },
    ).json()
    event_id = event_resp["event_id"]

    # Host is making mashed potatoes (no assignee)
    host_meal = client.post(
        f"/api/events/{event_id}/meals",
        json={
            "role": "side",
            "recipe_name": "Mashed potatoes",
            "servings": 6,
        },
    ).json()["meals"][0]

    # Kirsten is bringing kale salad (assigned) — so kale should NOT
    # show up on the grocery list.
    guest_meal = client.post(
        f"/api/events/{event_id}/meals",
        json={
            "role": "side",
            "recipe_name": "Kale salad",
            "servings": 6,
            "assigned_guest_id": kirsten["guest_id"],
        },
    ).json()["meals"][-1]

    # Add inline ingredients directly via DB — free-text dishes don't
    # have an ingredient capture UI yet, but the backend DOES store
    # EventMealIngredient rows via AI generation. We simulate that
    # scaffolding here to validate the filter.
    with session_scope() as session:
        session.add(
            EventMealIngredient(
                id=f"{host_meal['meal_id']}:0001",
                event_meal_id=host_meal["meal_id"],
                ingredient_name="Potatoes",
                normalized_name="potatoes",
                quantity=3.0,
                unit="lb",
                category="Produce",
            )
        )
        session.add(
            EventMealIngredient(
                id=f"{guest_meal['meal_id']}:0001",
                event_meal_id=guest_meal["meal_id"],
                ingredient_name="Kale",
                normalized_name="kale",
                quantity=2.0,
                unit="bunch",
                category="Produce",
            )
        )
        session.commit()

    # Trigger grocery regeneration
    resp = client.post(f"/api/events/{event_id}/grocery/refresh")
    assert resp.status_code == 200, resp.text

    grocery = resp.json()["grocery_items"]
    names = {g["ingredient_name"].lower() for g in grocery}
    assert any("potato" in n for n in names), "Host's dish ingredients should be on grocery"
    assert not any("kale" in n for n in names), "Guest-assigned dish should NOT be on grocery"


def test_event_grocery_merge_into_week_combines_matching_rows(client) -> None:
    """M10 Phase 3: merging event groceries into a week adds quantities
    to the matching weekly row when base_ingredient_id + unit match.
    """
    from app.db import session_scope
    from app.models import Event, EventGroceryItem, GroceryItem, Week

    # Seed a shared catalog ingredient so event + week both link to it.
    base_resp = client.post(
        "/api/ingredients",
        json={
            "name": "Chicken",
            "category": "Protein",
            "default_unit": "lb",
            "nutrition_reference_amount": 1,
            "nutrition_reference_unit": "lb",
            "calories": 500,
        },
    )
    base_id = base_resp.json()["base_ingredient_id"]

    # Create a week with an existing chicken grocery item.
    wk_resp = client.post("/api/weeks", json={"week_start": "2026-04-27"})
    assert wk_resp.status_code == 200
    week_id = wk_resp.json()["week_id"]
    with session_scope() as session:
        week = session.get(Week, week_id)
        session.add(
            GroceryItem(
                week_id=week.id,
                base_ingredient_id=base_id,
                ingredient_name="Chicken",
                normalized_name="chicken",
                total_quantity=1.0,
                unit="lb",
                category="Protein",
            )
        )
        session.commit()

    # Create an event with its own chicken grocery row (5 lb).
    event_resp = client.post(
        "/api/events",
        json={"name": "Party", "attendee_count": 5},
    )
    event_id = event_resp.json()["event_id"]
    with session_scope() as session:
        event = session.get(Event, event_id)
        session.add(
            EventGroceryItem(
                event_id=event.id,
                base_ingredient_id=base_id,
                ingredient_name="Chicken",
                normalized_name="chicken",
                total_quantity=5.0,
                unit="lb",
                category="Protein",
            )
        )
        session.commit()

    # Merge
    merge_resp = client.post(
        f"/api/events/{event_id}/grocery/merge",
        json={"week_id": week_id},
    )
    assert merge_resp.status_code == 200, merge_resp.text

    # Verify the weekly row is now 1 lb (week portion) + 5 lb (event
    # portion via M22.2's `event_quantity` column), and the event row
    # is tagged with merged_into_week_id.
    with session_scope() as session:
        week_rows = list(session.query(GroceryItem).filter_by(week_id=week_id).all())
        assert len(week_rows) == 1
        assert week_rows[0].total_quantity == 1.0
        assert week_rows[0].event_quantity == 5.0
        event_rows = list(session.query(EventGroceryItem).filter_by(event_id=event_id).all())
        assert event_rows[0].merged_into_week_id == week_id
        assert event_rows[0].merged_into_grocery_item_id == week_rows[0].id

    # Unmerge — event_quantity should clear; total_quantity stays at 1 lb.
    unmerge_resp = client.delete(
        f"/api/events/{event_id}/grocery/merge?week_id={week_id}"
    )
    assert unmerge_resp.status_code == 200
    with session_scope() as session:
        week_rows = list(session.query(GroceryItem).filter_by(week_id=week_id).all())
        assert week_rows[0].total_quantity == 1.0
        assert week_rows[0].event_quantity is None
        event_rows = list(session.query(EventGroceryItem).filter_by(event_id=event_id).all())
        assert event_rows[0].merged_into_week_id is None
