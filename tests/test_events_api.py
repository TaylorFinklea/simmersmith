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
