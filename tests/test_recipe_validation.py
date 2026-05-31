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
