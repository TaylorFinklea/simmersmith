"""AI-generated recipe header images (M14 Phase 2).

Calls OpenAI's `/v1/images/generations` endpoint with `gpt-image-1`
using the existing `SIMMERSMITH_AI_OPENAI_API_KEY`. Reusing the key
the rest of the AI stack already depends on keeps the surface area
small — no Vercel AI Gateway proxy, no separate Gemini key. The
service signature is provider-agnostic so a future milestone can
swap in Gemini's native API without touching the call site in
`app/api/recipes.py`.

OpenAI image-gen response shape (https://platform.openai.com/docs/api-reference/images/create):
  {"data": [{"b64_json": "<base64 payload>"}]}
"""
from __future__ import annotations

import base64
import logging
from typing import Any

import httpx

from app.config import Settings
from app.models import Recipe
from app.services.recipes import effective_recipe_data


logger = logging.getLogger(__name__)


# OpenAI's gpt-image-1 always returns PNG. If we ever switch model,
# this is the canonical fallback before we read the response shape.
_DEFAULT_MIME = "image/png"


class RecipeImageError(RuntimeError):
    """Recipe image generation failed (provider key not configured,
    HTTP error, malformed response, etc.). Carries a human-readable
    detail for logging."""


def is_image_gen_configured(settings: Settings) -> bool:
    """True when an OpenAI key is configured. Used to short-circuit
    the opportunistic on-create call so we don't spam logs when the
    key simply hasn't been set yet (e.g. local dev)."""
    return bool(settings.ai_openai_api_key.strip())


def generate_recipe_image(recipe: Recipe, *, settings: Settings) -> tuple[bytes, str, str]:
    """Generate a header image for `recipe`. Returns (bytes, mime, prompt).

    Raises `RecipeImageError` on any failure — the caller decides
    whether to swallow (best-effort) or surface (backfill).
    """
    if not is_image_gen_configured(settings):
        raise RecipeImageError("OpenAI API key not configured")

    prompt = _build_prompt(recipe)
    payload = {
        "model": settings.ai_image_model,
        "prompt": prompt,
        "n": 1,
        "size": "1024x1024",
    }
    headers = {
        "Authorization": f"Bearer {settings.ai_openai_api_key}",
        "Content-Type": "application/json",
    }

    try:
        with httpx.Client(timeout=settings.ai_timeout_seconds) as client:
            response = client.post(
                "https://api.openai.com/v1/images/generations",
                json=payload,
                headers=headers,
            )
    except httpx.HTTPError as exc:
        raise RecipeImageError(f"Image request failed: {exc}") from exc

    if response.status_code >= 400:
        raise RecipeImageError(f"OpenAI returned {response.status_code}: {response.text[:200]}")

    try:
        body: dict[str, Any] = response.json()
    except ValueError as exc:
        raise RecipeImageError(f"Image response was not JSON: {exc}") from exc

    image_bytes, mime = _extract_image(body)
    return image_bytes, mime, prompt


def _build_prompt(recipe: Recipe) -> str:
    """Compose the text prompt sent to the image model. Uses the
    recipe's effective name + cuisine + top ingredients so the
    generator has something concrete to work with — empty fields
    just collapse out of the prompt."""
    data = effective_recipe_data(recipe)
    name = str(data.get("name") or "").strip() or "a meal"
    cuisine = str(data.get("cuisine") or "").strip()
    ingredients = data.get("ingredients") or []
    top_ingredients: list[str] = []
    for ing in ingredients[:5]:
        if isinstance(ing, dict):
            label = str(ing.get("ingredient_name") or "").strip()
        else:
            label = str(getattr(ing, "ingredient_name", "")).strip()
        if label:
            top_ingredients.append(label)

    parts = [
        f"A photographic, top-down shot of {name}",
    ]
    if cuisine:
        parts.append(f"a {cuisine} dish")
    parts.append("plated on a wooden table, soft natural light, no text, no watermarks")
    if top_ingredients:
        parts.append("Visible ingredients: " + ", ".join(top_ingredients))
    return ". ".join(parts) + "."


def _extract_image(body: dict[str, Any]) -> tuple[bytes, str]:
    """Pull the first base64 image payload out of an OpenAI
    images-generations response. `gpt-image-1` always returns
    `b64_json`. Older `dall-e-*` models can return `url` instead;
    we support that as a fallback by fetching the URL."""
    items = body.get("data") or []
    if not items:
        raise RecipeImageError("Image response had no data array")
    first = items[0] or {}
    if isinstance(first.get("b64_json"), str) and first["b64_json"]:
        try:
            return base64.b64decode(first["b64_json"]), _DEFAULT_MIME
        except (ValueError, TypeError) as exc:
            raise RecipeImageError(f"Image base64 decode failed: {exc}") from exc
    url = first.get("url")
    if isinstance(url, str) and url.startswith("http"):
        try:
            with httpx.Client(timeout=30.0) as client:
                resp = client.get(url)
                resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise RecipeImageError(f"Could not fetch image URL: {exc}") from exc
        mime = resp.headers.get("content-type", _DEFAULT_MIME).split(";", 1)[0].strip() or _DEFAULT_MIME
        return resp.content, mime
    raise RecipeImageError("Image response did not contain a base64 payload or URL")
