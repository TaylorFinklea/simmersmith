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
                "app.api.recipes.is_image_gen_configured",
                return_value=True,
            )
        )
        patches.append(
            patch(
                "app.api.recipes.generate_recipe_image",
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


def test_regenerate_replaces_bytes_and_busts_cache(client) -> None:
    """Regenerate produces fresh bytes + a fresh `?v=` cache-buster
    on the recipe payload's image_url."""
    import time

    response, _ = _post_recipe(client)
    body = response.json()
    recipe_id = body["recipe_id"]
    original_url = body["image_url"]

    # Make sure the regenerate run produces a different ETag —
    # sleep a beat so the generated_at timestamp moves.
    time.sleep(1.1)

    new_bytes = b"\x89PNG\r\n\x1a\n REGEN " + b"x" * 32
    with patch(
        "app.api.recipe_images.is_image_gen_configured",
        return_value=True,
    ), patch(
        "app.api.recipe_images.generate_recipe_image",
        return_value=(new_bytes, "image/png", "regen prompt"),
    ):
        regen_resp = client.post(f"/api/recipes/{recipe_id}/image/regenerate")

    assert regen_resp.status_code == 200, regen_resp.text
    regen_body = regen_resp.json()
    assert regen_body["image_url"] is not None
    assert regen_body["image_url"] != original_url

    # The streamed bytes match what the regen returned.
    image_resp = client.get(f"/api/recipes/{recipe_id}/image")
    assert image_resp.status_code == 200
    assert image_resp.content == new_bytes


def test_upload_replaces_with_user_bytes(client) -> None:
    """PUT /api/recipes/{id}/image overwrites the row with the
    given base64 bytes."""
    import base64

    response, _ = _post_recipe(client)
    recipe_id = response.json()["recipe_id"]

    user_bytes = b"\xff\xd8\xff\xe0 USER PHOTO " + b"x" * 32  # JPEG-ish header
    upload_resp = client.put(
        f"/api/recipes/{recipe_id}/image",
        json={
            "image_base64": base64.b64encode(user_bytes).decode("ascii"),
            "mime_type": "image/jpeg",
        },
    )
    assert upload_resp.status_code == 200, upload_resp.text
    assert upload_resp.json()["image_url"] is not None

    image_resp = client.get(f"/api/recipes/{recipe_id}/image")
    assert image_resp.status_code == 200
    assert image_resp.content == user_bytes
    assert image_resp.headers["content-type"].startswith("image/jpeg")


def test_delete_removes_row_and_clears_image_url(client) -> None:
    """DELETE drops the row → recipe payload has no image_url and
    GET .../image 404s."""
    response, _ = _post_recipe(client)
    recipe_id = response.json()["recipe_id"]

    delete_resp = client.delete(f"/api/recipes/{recipe_id}/image")
    assert delete_resp.status_code == 200, delete_resp.text
    assert delete_resp.json()["image_url"] is None

    image_resp = client.get(f"/api/recipes/{recipe_id}/image")
    assert image_resp.status_code == 404

    # Idempotent — calling delete on a recipe with no image is fine.
    second = client.delete(f"/api/recipes/{recipe_id}/image")
    assert second.status_code == 200


def test_save_recipe_uses_user_image_provider(client) -> None:
    """When the user's `image_provider` profile row is `gemini`, the
    on-create hook routes to `_generate_via_gemini` and skips OpenAI."""
    from app.services.recipe_difficulty_ai import DifficultyAssessment

    profile_resp = client.put(
        "/api/profile",
        json={"settings": {"image_provider": "gemini"}},
    )
    assert profile_resp.status_code == 200, profile_resp.text

    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty",
        return_value=DifficultyAssessment(score=2, kid_friendly=False, reason=""),
    ), patch(
        "app.api.recipes.is_image_gen_configured", return_value=True,
    ), patch(
        "app.services.recipe_image_ai._generate_via_gemini",
        return_value=(_png_bytes(), "image/png", "gemini prompt"),
    ) as gemini_mock, patch(
        "app.services.recipe_image_ai._generate_via_openai",
        return_value=(_png_bytes(), "image/png", "openai prompt"),
    ) as openai_mock:
        response = client.post("/api/recipes", json=_payload())

    assert response.status_code == 200, response.text
    assert gemini_mock.call_count == 1
    assert openai_mock.call_count == 0
    assert response.json()["image_url"] is not None


def test_regenerate_503s_when_user_provider_unconfigured(client) -> None:
    """User picks `gemini` but `ai_gemini_api_key` is empty (default).
    The regenerate route returns 503."""
    from app.services.recipe_difficulty_ai import DifficultyAssessment

    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty",
        return_value=DifficultyAssessment(score=2, kid_friendly=False, reason=""),
    ):
        save_resp = client.post("/api/recipes", json=_payload())
    assert save_resp.status_code == 200, save_resp.text
    recipe_id = save_resp.json()["recipe_id"]

    profile_resp = client.put(
        "/api/profile",
        json={"settings": {"image_provider": "gemini"}},
    )
    assert profile_resp.status_code == 200

    regen_resp = client.post(f"/api/recipes/{recipe_id}/image/regenerate")
    assert regen_resp.status_code == 503


def test_default_provider_remains_openai(client) -> None:
    """No `image_provider` row + default global setting → existing
    OpenAI behavior is preserved."""
    from app.services.recipe_difficulty_ai import DifficultyAssessment

    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty",
        return_value=DifficultyAssessment(score=2, kid_friendly=False, reason=""),
    ), patch(
        "app.api.recipes.is_image_gen_configured", return_value=True,
    ), patch(
        "app.services.recipe_image_ai._generate_via_openai",
        return_value=(_png_bytes(), "image/png", "openai prompt"),
    ) as openai_mock, patch(
        "app.services.recipe_image_ai._generate_via_gemini",
        return_value=(_png_bytes(), "image/png", "gemini prompt"),
    ) as gemini_mock:
        response = client.post("/api/recipes", json=_payload())

    assert response.status_code == 200, response.text
    assert openai_mock.call_count == 1
    assert gemini_mock.call_count == 0


def test_image_gen_failure_does_not_block_save(client) -> None:
    """If the gateway throws, the save still succeeds and the
    recipe just lacks an image (gradient fallback on the client)."""
    from app.services.recipe_image_ai import RecipeImageError
    from app.services.recipe_difficulty_ai import DifficultyAssessment

    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty",
        return_value=DifficultyAssessment(score=2, kid_friendly=False, reason=""),
    ), patch(
        "app.api.recipes.is_image_gen_configured",
        return_value=True,
    ), patch(
        "app.api.recipes.generate_recipe_image",
        side_effect=RecipeImageError("provider down"),
    ):
        response = client.post("/api/recipes", json=_payload())

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["image_url"] is None
