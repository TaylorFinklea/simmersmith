"""AI-generated recipe header images.

Two providers, picked per-user via the `image_provider` row in
`profile_settings` (falls back to `settings.ai_image_provider`):
- **OpenAI** (`gpt-image-1`) — `/v1/images/generations`, returns
  `{"data": [{"b64_json": "..."}]}`.
- **Gemini** (`gemini-2.5-flash-image-preview`) —
  `/v1beta/models/{model}:generateContent`, returns
  `{"candidates":[{"content":{"parts":[{"inlineData":{"data": "..."}}]}}]}`.

Both providers share `_build_prompt` so variety is provider-driven,
not prompt-driven. Both raise `RecipeImageError` on any failure;
callers decide whether to swallow (best-effort save) or surface
(backfill / regenerate).
"""
from __future__ import annotations

import base64
import logging
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import Recipe, RecipeImage
from app.models._base import utcnow
from app.services.recipes import effective_recipe_data


logger = logging.getLogger(__name__)


# Both OpenAI's gpt-image-1 and Gemini's flash-image-preview default
# to PNG. Used as the fallback before reading the response shape.
_DEFAULT_MIME = "image/png"

_VALID_PROVIDERS = ("openai", "gemini")


class RecipeImageError(RuntimeError):
    """Recipe image generation failed (provider key not configured,
    HTTP error, malformed response, etc.). Carries a human-readable
    detail for logging."""


def recipe_has_image(session: Session, recipe_id: str) -> bool:
    """True when a `recipe_images` row already exists for this recipe."""
    return session.scalar(
        select(RecipeImage.recipe_id).where(RecipeImage.recipe_id == recipe_id)
    ) is not None


def persist_recipe_image(
    session: Session,
    recipe_id: str,
    image_bytes: bytes,
    mime_type: str,
    prompt: str,
) -> None:
    """Upsert a recipe image row. Caller is responsible for the
    surrounding `session.commit()` / 503 handling."""
    existing = session.scalar(
        select(RecipeImage).where(RecipeImage.recipe_id == recipe_id)
    )
    if existing is not None:
        existing.image_bytes = image_bytes
        existing.mime_type = mime_type
        existing.prompt = prompt
        existing.generated_at = utcnow()
        return
    session.add(
        RecipeImage(
            recipe_id=recipe_id,
            image_bytes=image_bytes,
            mime_type=mime_type,
            prompt=prompt,
        )
    )


def _resolve_provider(
    settings: Settings, user_settings: dict[str, str] | None
) -> str:
    """Pick the provider for this call. The user's `image_provider`
    profile row wins when it's a known value; otherwise fall back to
    the global `ai_image_provider` setting; otherwise OpenAI."""
    user_choice = str((user_settings or {}).get("image_provider", "")).strip().lower()
    if user_choice in _VALID_PROVIDERS:
        return user_choice
    global_choice = str(settings.ai_image_provider or "").strip().lower()
    if global_choice in _VALID_PROVIDERS:
        return global_choice
    return "openai"


def is_image_gen_configured(
    settings: Settings, *, user_settings: dict[str, str] | None = None
) -> bool:
    """True when the resolved provider has its key configured. Used
    to short-circuit the opportunistic on-create call so we don't
    spam logs when the key simply hasn't been set yet (local dev)."""
    provider = _resolve_provider(settings, user_settings)
    if provider == "gemini":
        return bool(settings.ai_gemini_api_key.strip())
    return bool(settings.ai_openai_api_key.strip())


def generate_recipe_image(
    recipe: Recipe,
    *,
    settings: Settings,
    user_settings: dict[str, str] | None = None,
) -> tuple[bytes, str, str]:
    """Generate a header image for `recipe`. Returns (bytes, mime, prompt).

    Dispatches to the user's chosen provider (or the global default).
    Raises `RecipeImageError` on any failure — the caller decides
    whether to swallow (best-effort) or surface (backfill / regen).
    """
    provider = _resolve_provider(settings, user_settings)
    if provider == "gemini":
        return _generate_via_gemini(recipe, settings=settings)
    return _generate_via_openai(recipe, settings=settings)


def _generate_via_openai(recipe: Recipe, *, settings: Settings) -> tuple[bytes, str, str]:
    if not settings.ai_openai_api_key.strip():
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

    image_bytes, mime = _extract_openai_image(body)
    return image_bytes, mime, prompt


def _generate_via_gemini(recipe: Recipe, *, settings: Settings) -> tuple[bytes, str, str]:
    if not settings.ai_gemini_api_key.strip():
        raise RecipeImageError("Gemini API key not configured")

    prompt = _build_prompt(recipe)
    payload = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    headers = {
        "x-goog-api-key": settings.ai_gemini_api_key,
        "Content-Type": "application/json",
    }
    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{settings.ai_gemini_image_model}:generateContent"
    )

    try:
        with httpx.Client(timeout=settings.ai_timeout_seconds) as client:
            response = client.post(url, json=payload, headers=headers)
    except httpx.HTTPError as exc:
        raise RecipeImageError(f"Image request failed: {exc}") from exc

    if response.status_code >= 400:
        raise RecipeImageError(f"Gemini returned {response.status_code}: {response.text[:200]}")

    try:
        body: dict[str, Any] = response.json()
    except ValueError as exc:
        raise RecipeImageError(f"Image response was not JSON: {exc}") from exc

    image_bytes, mime = _extract_gemini_image(body)
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


def _extract_openai_image(body: dict[str, Any]) -> tuple[bytes, str]:
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


def _extract_gemini_image(body: dict[str, Any]) -> tuple[bytes, str]:
    """Walk a Gemini `:generateContent` response for the first
    `inline_data` (snake_case) or `inlineData` (camelCase) part.
    Either casing can show up depending on API minor version.
    Returns the decoded bytes + mime type."""
    candidates = body.get("candidates") or []
    if not candidates:
        raise RecipeImageError("Gemini response had no candidates")
    content = (candidates[0] or {}).get("content") or {}
    parts = content.get("parts") or []
    for part in parts:
        if not isinstance(part, dict):
            continue
        inline = part.get("inlineData") or part.get("inline_data")
        if not isinstance(inline, dict):
            continue
        data = inline.get("data")
        if not isinstance(data, str) or not data:
            continue
        mime = str(inline.get("mimeType") or inline.get("mime_type") or _DEFAULT_MIME)
        try:
            return base64.b64decode(data), mime
        except (ValueError, TypeError) as exc:
            raise RecipeImageError(f"Image base64 decode failed: {exc}") from exc
    raise RecipeImageError("Gemini response did not contain an inline_data part")
