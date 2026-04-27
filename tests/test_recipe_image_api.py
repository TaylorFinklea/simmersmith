"""Tests for AI-generated recipe header images (M14).

Covers:
- The serve route returns bytes + ETag for an existing image row.
- The serve route 404s when the recipe has no image.
- The on-create AI call fires once per save when configured.
- An AI failure during the on-create path doesn't block the save.
"""
from __future__ import annotations

from unittest.mock import patch


def _payload(name: str = "Sunset Curry") -> dict:
    return {
        "name": name,
        "meal_type": "dinner",
        "cuisine": "Indian",
        "servings": 4.0,
        "ingredients": [
            {"ingredient_name": "chicken thigh", "quantity": 1.0, "unit": "lb"},
            {"ingredient_name": "coconut milk", "quantity": 1.0, "unit": "can"},
        ],
        "steps": [
            {"step_number": 0, "instruction": "Sauté the aromatics."},
            {"step_number": 1, "instruction": "Simmer with coconut milk."},
        ],
    }


def _png_bytes() -> bytes:
    """Tiny valid PNG header. The route is content-agnostic — it
    just needs *some* bytes to stream back."""
    return (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
        b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\xdac\xf8\xff\xff"
        b"?\x00\x05\xfe\x02\xfe\xa3\x9d\xb1\x9b\x00\x00\x00\x00IEND\xaeB`\x82"
    )


def _post_recipe(client, *, with_difficulty: bool = True, with_image: bool = True):
    """Save a recipe through the create route, mocking the AI calls
    that fire from the route. Returns the response."""
    targets: list[str] = []
    patches = []

    # Difficulty AI runs first; mock it to a no-op so the test stays
    # focused on the image-gen path.
    if with_difficulty:
        from app.services.recipe_difficulty_ai import DifficultyAssessment

        patches.append(
            patch(
                "app.services.recipe_difficulty_ai.infer_recipe_difficulty",
                return_value=DifficultyAssessment(score=2, kid_friendly=False, reason=""),
            )
        )

    if with_image:
        patches.append(
            patch(
                "app.services.recipe_image_ai.is_image_gen_configured",
                return_value=True,
            )
        )
        patches.append(
            patch(
                "app.services.recipe_image_ai.generate_recipe_image",
                return_value=(_png_bytes(), "image/png", "test prompt"),
            )
        )

    with _stack(patches) as exits:
        targets = exits
        return client.post("/api/recipes", json=_payload()), targets


class _stack:
    """Tiny context manager helper to enter a list of patches and
    return the list of mock objects on enter."""

    def __init__(self, patches):
        self._patches = patches
        self._mocks: list = []

    def __enter__(self):
        for p in self._patches:
            self._mocks.append(p.__enter__())
        return self._mocks

    def __exit__(self, *exc):
        for p in reversed(self._patches):
            p.__exit__(*exc)


def test_image_route_streams_bytes_with_etag(client) -> None:
    """After a recipe is saved with image-gen mocked, the GET image
    route returns the bytes + a versioned ETag."""
    response, _ = _post_recipe(client)
    assert response.status_code == 200, response.text
    body = response.json()
    recipe_id = body["recipe_id"]
    assert body["image_url"] is not None
    assert f"/api/recipes/{recipe_id}/image?v=" in body["image_url"]

    image_resp = client.get(f"/api/recipes/{recipe_id}/image")
    assert image_resp.status_code == 200
    assert image_resp.headers["content-type"].startswith("image/png")
    assert image_resp.headers.get("etag", "").strip('"').isdigit()
    assert "immutable" in image_resp.headers.get("cache-control", "")
    assert image_resp.content == _png_bytes()


def test_image_route_404s_when_no_image_yet(client) -> None:
    """A recipe saved without the image-gen path having run returns
    no image_url, and the GET image route 404s."""
    response, _ = _post_recipe(client, with_image=False)
    assert response.status_code == 200, response.text
    body = response.json()
    recipe_id = body["recipe_id"]
    assert body["image_url"] is None

    image_resp = client.get(f"/api/recipes/{recipe_id}/image")
    assert image_resp.status_code == 404


def test_image_gen_called_once_on_save(client) -> None:
    """The generator should fire exactly once per save when the
    gateway is configured and the recipe has no image yet."""
    response, mocks = _post_recipe(client)
    assert response.status_code == 200
    # mocks: [difficulty, is_configured, generate_recipe_image]
    generate_mock = mocks[2]
    assert generate_mock.call_count == 1


def test_image_gen_failure_does_not_block_save(client) -> None:
    """If the gateway throws, the save still succeeds and the
    recipe just lacks an image (gradient fallback on the client)."""
    from app.services.recipe_image_ai import RecipeImageError
    from app.services.recipe_difficulty_ai import DifficultyAssessment

    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty",
        return_value=DifficultyAssessment(score=2, kid_friendly=False, reason=""),
    ), patch(
        "app.services.recipe_image_ai.is_image_gen_configured",
        return_value=True,
    ), patch(
        "app.services.recipe_image_ai.generate_recipe_image",
        side_effect=RecipeImageError("provider down"),
    ):
        response = client.post("/api/recipes", json=_payload())

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["image_url"] is None
