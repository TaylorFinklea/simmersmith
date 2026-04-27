"""AI-generated recipe header images (M14 Phase 2).

Calls Gemini 2.5 Flash Image Preview ("Nano Banana") through the
Vercel AI Gateway's OpenAI-compatible chat-completions endpoint.
Returns the raw image bytes + mime type. Failure raises
`RecipeImageError` so the caller can decide whether to swallow it
(opportunistic best-effort path on recipe save) or surface it
(explicit backfill flow).

Reference shape from Vercel AI Gateway docs:
  POST {ai_gateway_url}/chat/completions
  body: {model, messages, modalities: ["image"]}
  response: choices[0].message.images[0].image_url.url
            data URI: "data:image/png;base64,...."
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


class RecipeImageError(RuntimeError):
    """Recipe image generation failed (gateway not configured, HTTP
    error, malformed response, etc.). Carry a human-readable detail
    for logging."""


def is_image_gen_configured(settings: Settings) -> bool:
    """True when the Vercel AI Gateway is reachable. Used to short-
    circuit the opportunistic on-create call so we don't spam logs
    when the secret simply hasn't been set yet (e.g. local dev)."""
    return bool(settings.ai_gateway_api_key.strip() and settings.ai_gateway_url.strip())


def generate_recipe_image(recipe: Recipe, *, settings: Settings) -> tuple[bytes, str, str]:
    """Generate a header image for `recipe`. Returns (bytes, mime, prompt).

    Raises `RecipeImageError` on any failure — the caller decides
    whether to swallow (best-effort) or surface (backfill).
    """
    if not is_image_gen_configured(settings):
        raise RecipeImageError("Vercel AI Gateway not configured")

    prompt = _build_prompt(recipe)
    base_url = settings.ai_gateway_url.rstrip("/")
    url = f"{base_url}/chat/completions"
    payload = {
        "model": settings.ai_gateway_image_model,
        "messages": [{"role": "user", "content": prompt}],
        "modalities": ["image"],
    }
    headers = {
        "Authorization": f"Bearer {settings.ai_gateway_api_key}",
        "Content-Type": "application/json",
    }

    try:
        with httpx.Client(timeout=settings.ai_timeout_seconds) as client:
            response = client.post(url, json=payload, headers=headers)
    except httpx.HTTPError as exc:
        raise RecipeImageError(f"Gateway request failed: {exc}") from exc

    if response.status_code >= 400:
        raise RecipeImageError(f"Gateway returned {response.status_code}: {response.text[:200]}")

    try:
        body: dict[str, Any] = response.json()
    except ValueError as exc:
        raise RecipeImageError(f"Gateway response was not JSON: {exc}") from exc

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
    """Pull the first image attachment out of an OpenAI-compatible
    chat-completions response. Vercel AI Gateway puts image
    attachments under `choices[0].message.images[].image_url.url`
    as a base64 data URI."""
    choices = body.get("choices") or []
    if not choices:
        raise RecipeImageError("Gateway response had no choices")
    message = (choices[0] or {}).get("message") or {}
    images = message.get("images") or []
    for image in images:
        url = ((image or {}).get("image_url") or {}).get("url") or ""
        if isinstance(url, str) and url.startswith("data:"):
            return _decode_data_uri(url)
    # Fallback: some providers stuff the image in `content` blocks.
    for block in message.get("content") or []:
        if isinstance(block, dict):
            url = (block.get("image_url") or {}).get("url") or ""
            if isinstance(url, str) and url.startswith("data:"):
                return _decode_data_uri(url)
    raise RecipeImageError("Gateway response did not contain an image")


def _decode_data_uri(uri: str) -> tuple[bytes, str]:
    """`data:image/png;base64,<payload>` → (bytes, mime)."""
    header, _, payload = uri.partition(",")
    if not payload:
        raise RecipeImageError("Image data URI was empty")
    mime = "image/png"
    if header.startswith("data:") and ";" in header:
        mime = header[len("data:"):].split(";", 1)[0] or mime
    try:
        return base64.b64decode(payload), mime
    except (ValueError, TypeError) as exc:
        raise RecipeImageError(f"Image base64 decode failed: {exc}") from exc
