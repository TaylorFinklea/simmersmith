"""In-season produce snapshot.

One AI call per (region, year, month) that returns 5–8 produce items
with a short "why now" reason. The result is the same for every user
in a given region/month, so we cache it in a module-level dict and
let the cache evict naturally on app restart or month rollover.

Mirrors the strict-JSON pattern in `pairing_ai.py`.
"""
from __future__ import annotations

import json
import logging
import threading
from dataclasses import dataclass
from datetime import date

from pydantic import BaseModel, Field, ValidationError

from app.config import Settings
from app.services.ai import (
    SUPPORTED_DIRECT_PROVIDERS,
    direct_provider_availability,
    resolve_direct_model,
)
from app.services.assistant_ai import (
    AssistantExecutionTarget,
    extract_json_object,
    run_direct_provider,
)

logger = logging.getLogger(__name__)


class InSeasonItem(BaseModel):
    name: str
    why_now: str = ""
    peak_score: int = Field(default=3, ge=1, le=5)


class _AIResponse(BaseModel):
    items: list[InSeasonItem] = Field(default_factory=list)


@dataclass(frozen=True)
class _Target:
    provider_name: str
    model: str


# Module-level cache. Module reload (e.g., test restart) clears it for free.
_CACHE: dict[tuple[str, int, int], list[InSeasonItem]] = {}
_CACHE_LOCK = threading.Lock()
_DEFAULT_REGION = "United States"


def _resolve_target(settings: Settings, user_settings: dict[str, str]) -> _Target:
    preferred = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    candidates: list[str] = []
    if preferred in SUPPORTED_DIRECT_PROVIDERS:
        candidates.append(preferred)
    for name in SUPPORTED_DIRECT_PROVIDERS:
        if name not in candidates:
            candidates.append(name)
    for name in candidates:
        available, _ = direct_provider_availability(
            name, settings=settings, user_settings=user_settings
        )
        if available:
            model = resolve_direct_model(name, settings=settings, user_settings=user_settings)
            return _Target(provider_name=name, model=model)
    raise RuntimeError("No direct AI provider is configured for seasonal produce.")


_MONTH_NAMES = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)


def _build_prompt(*, region: str, year: int, month: int) -> str:
    schema_hint = (
        '{"items": [{"name": "...", "why_now": "...", "peak_score": 1-5}]}'
    )
    month_name = _MONTH_NAMES[month - 1] if 1 <= month <= 12 else "this month"
    return (
        "List 5–8 produce items that are in peak season right now for the "
        "region described below. Bias toward fresh fruit + vegetables a home "
        "cook would actually buy at a grocery store or farmers' market. "
        "Return ONLY a JSON object.\n\n"
        f"Region: {region}\n"
        f"Month: {month_name} {year}\n\n"
        "Rules:\n"
        "- 5–8 items. Each `name` is a short common name (e.g., 'asparagus').\n"
        "- `why_now` is one short sentence about *why* it's at peak now.\n"
        "- `peak_score` is 1–5: 5 = absolute peak, 1 = barely available.\n"
        "- Order best-first by `peak_score`.\n\n"
        f"Return ONLY a JSON object matching:\n{schema_hint}\n"
    )


def _parse_response(raw: str) -> list[InSeasonItem]:
    candidate = extract_json_object(raw)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI returned invalid JSON for seasonal produce.") from exc
    try:
        parsed = _AIResponse.model_validate(payload)
    except ValidationError as exc:
        raise RuntimeError("Seasonal AI response did not match the expected shape.") from exc
    items: list[InSeasonItem] = []
    for entry in parsed.items:
        name = entry.name.strip()
        if not name:
            continue
        items.append(
            InSeasonItem(name=name, why_now=entry.why_now.strip(), peak_score=entry.peak_score)
        )
    return items[:8]


def seasonal_produce(
    *,
    region: str | None,
    today: date | None = None,
    settings: Settings,
    user_settings: dict[str, str],
) -> list[InSeasonItem]:
    """Return cached or fresh in-season items for `region` and `today`'s month.

    Empty/whitespace `region` falls back to "United States". Cache key is
    `(region, year, month)` so a user moving from Kansas to California gets
    a fresh fetch without restarting the app.
    """
    today = today or date.today()
    normalized = (region or "").strip() or _DEFAULT_REGION
    key = (normalized, today.year, today.month)

    with _CACHE_LOCK:
        cached = _CACHE.get(key)
    if cached is not None:
        return cached

    target = _resolve_target(settings, user_settings)
    execution_target = AssistantExecutionTarget(
        provider_kind="direct",
        source="seasonal_produce",
        provider_name=target.provider_name,
        model=target.model,
    )
    raw = run_direct_provider(
        target=execution_target,
        settings=settings,
        user_settings=user_settings,
        prompt=_build_prompt(region=normalized, year=today.year, month=today.month),
    )
    items = _parse_response(raw)
    with _CACHE_LOCK:
        _CACHE[key] = items
    return items


def clear_cache() -> None:
    """Test helper — wipes the in-process cache."""
    with _CACHE_LOCK:
        _CACHE.clear()
