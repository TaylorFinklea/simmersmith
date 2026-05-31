"""M53: difficulty_score is bounded 1..5 at the API boundary (matches the
DB CHECK), so an out-of-range value is a 422, not a 500."""
from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import app


def test_recipe_save_rejects_out_of_range_difficulty() -> None:
    with TestClient(app) as client:
        for bad in (0, 6, -1):
            resp = client.post("/api/recipes", json={"name": "x", "difficulty_score": bad})
            assert resp.status_code == 422, f"{bad}: {resp.text}"
        ok = client.post("/api/recipes", json={"name": "ok", "difficulty_score": 3})
        assert ok.status_code == 200, ok.text


def test_import_from_text_rejects_oversized_body() -> None:
    # M61: a multi-MB paste is a 422 (schema cap), not an event-loop-blocking
    # regex run.
    with TestClient(app) as client:
        resp = client.post(
            "/api/recipes/import-from-text",
            json={"text": "x" * 600_000},
        )
        assert resp.status_code == 422, resp.text


def test_vision_rejects_oversized_image() -> None:
    # M39: oversized base64 is rejected before the decode buffer is allocated.
    with TestClient(app) as client:
        resp = client.post(
            "/api/vision/identify-ingredient",
            json={"image_base64": "A" * (8 * 1024 * 1024)},
        )
        assert resp.status_code == 400, resp.text
