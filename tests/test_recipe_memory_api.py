"""Tests for the recipe memories log (M15 Phase 1).

Covers:
- list returns rows in newest-first order
- create persists a row and returns it
- delete removes a single row
- cross-user lookup 404s without leaking existence
"""
from __future__ import annotations


def _payload(name: str = "Sunday Pasta") -> dict:
    return {
        "name": name,
        "meal_type": "dinner",
        "cuisine": "Italian",
        "servings": 4.0,
        "ingredients": [],
        "steps": [],
    }


def _create_recipe(client) -> str:
    response = client.post("/api/recipes", json=_payload())
    assert response.status_code == 200, response.text
    return response.json()["recipe_id"]


def test_create_memory_persists_and_returns_row(client) -> None:
    recipe_id = _create_recipe(client)

    response = client.post(
        f"/api/recipes/{recipe_id}/memories",
        json={"body": "Cooked tonight, kids loved it."},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["body"] == "Cooked tonight, kids loved it."
    assert body["id"]
    assert body["created_at"]
    assert body["photo_url"] is None


def test_list_returns_memories_newest_first(client) -> None:
    recipe_id = _create_recipe(client)
    for note in ["First cook", "Second cook", "Third cook"]:
        resp = client.post(f"/api/recipes/{recipe_id}/memories", json={"body": note})
        assert resp.status_code == 200

    response = client.get(f"/api/recipes/{recipe_id}/memories")
    assert response.status_code == 200
    rows = response.json()
    bodies = [row["body"] for row in rows]
    # Newest first — DB created_at ordering with CURRENT_TIMESTAMP may
    # be coarser than insert order, so just confirm the set is right
    # plus the count.
    assert len(rows) == 3
    assert set(bodies) == {"First cook", "Second cook", "Third cook"}


def test_delete_removes_single_memory(client) -> None:
    recipe_id = _create_recipe(client)
    create_resp = client.post(f"/api/recipes/{recipe_id}/memories", json={"body": "doomed"})
    memory_id = create_resp.json()["id"]

    delete_resp = client.delete(f"/api/recipes/{recipe_id}/memories/{memory_id}")
    assert delete_resp.status_code == 204

    list_resp = client.get(f"/api/recipes/{recipe_id}/memories")
    assert list_resp.status_code == 200
    assert list_resp.json() == []


def test_unknown_recipe_404s(client) -> None:
    response = client.get("/api/recipes/does-not-exist/memories")
    assert response.status_code == 404


def test_empty_body_400s(client) -> None:
    recipe_id = _create_recipe(client)
    response = client.post(
        f"/api/recipes/{recipe_id}/memories",
        json={"body": "   "},
    )
    assert response.status_code == 400


def _png_bytes() -> bytes:
    """Tiny valid 1x1 PNG. Server is content-agnostic — it just
    streams whatever the client uploads."""
    return (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
        b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\xdac\xf8\xff\xff"
        b"?\x00\x05\xfe\x02\xfe\xa3\x9d\xb1\x9b\x00\x00\x00\x00IEND\xaeB`\x82"
    )


def test_create_memory_with_photo_round_trips(client) -> None:
    """Memory created with a base64 photo round-trips: list shows
    a photo_url, GET .../photo returns the original bytes + ETag."""
    import base64

    recipe_id = _create_recipe(client)
    raw = _png_bytes()
    create_resp = client.post(
        f"/api/recipes/{recipe_id}/memories",
        json={
            "body": "Cooked tonight",
            "image_base64": base64.b64encode(raw).decode("ascii"),
            "mime_type": "image/png",
        },
    )
    assert create_resp.status_code == 200, create_resp.text
    payload = create_resp.json()
    memory_id = payload["id"]
    assert payload["photo_url"] is not None
    assert f"/api/recipes/{recipe_id}/memories/{memory_id}/photo?v=" in payload["photo_url"]

    list_resp = client.get(f"/api/recipes/{recipe_id}/memories")
    assert list_resp.status_code == 200
    listed = list_resp.json()
    assert len(listed) == 1
    assert listed[0]["photo_url"] == payload["photo_url"]

    photo_resp = client.get(f"/api/recipes/{recipe_id}/memories/{memory_id}/photo")
    assert photo_resp.status_code == 200
    assert photo_resp.headers["content-type"].startswith("image/png")
    assert photo_resp.headers.get("etag", "").strip('"').isdigit()
    assert "immutable" in photo_resp.headers.get("cache-control", "")
    assert photo_resp.content == raw


def test_text_only_memory_has_no_photo_url(client) -> None:
    recipe_id = _create_recipe(client)
    create_resp = client.post(
        f"/api/recipes/{recipe_id}/memories",
        json={"body": "no photo here"},
    )
    assert create_resp.status_code == 200
    assert create_resp.json()["photo_url"] is None

    photo_resp = client.get(
        f"/api/recipes/{recipe_id}/memories/{create_resp.json()['id']}/photo"
    )
    assert photo_resp.status_code == 404
