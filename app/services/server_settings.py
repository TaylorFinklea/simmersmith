"""Build 94 — operator-tunable server settings.

Wraps the ``server_settings`` table with typed accessors and sensible
defaults. Used by the entitlements / AI provider layers as the source
of truth for runtime-editable knobs (free-tier limits, default AI
models, trial-mode toggle). Reads always fall back to a hard-coded
default so an empty table behaves identically to today's hard-coded
config.

Three setting families:

- ``free_tier_limits`` — JSON-encoded dict ``{action: limit}``
- ``ai_openai_model`` / ``ai_anthropic_model`` — single-string defaults
- ``trial_mode_enabled`` — "1" / "0"

The admin site reads + writes via these helpers so the FastAPI
endpoints don't have to know the value shapes.
"""
from __future__ import annotations

import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.models import ServerSetting, utcnow


# Hard-coded defaults. Match the original ``FREE_TIER_LIMITS`` dict +
# the ``Settings`` env-driven defaults so the system behaves
# identically to pre-build-94 if the server_settings table is empty.
_FREE_TIER_LIMITS_DEFAULT: dict[str, int] = {
    "ai_generate": 1,
    "pricing_fetch": 1,
    "rebalance_day": 0,
    "recipe_import": 5,
}

KEY_FREE_TIER_LIMITS = "free_tier_limits"
KEY_OPENAI_MODEL = "ai_openai_model"
KEY_ANTHROPIC_MODEL = "ai_anthropic_model"
KEY_TRIAL_MODE = "trial_mode_enabled"


# ---------------------------------------------------------------------------
# raw get / set
# ---------------------------------------------------------------------------


def _row(session: Session, key: str) -> ServerSetting | None:
    return session.scalar(select(ServerSetting).where(ServerSetting.key == key))


def get_value(session: Session, key: str) -> str | None:
    row = _row(session, key)
    if row is None:
        return None
    return row.value


def set_value(session: Session, key: str, value: str) -> None:
    """Upsert a value. Empty string is a valid value — callers wanting
    "clear back to default" should ``delete_value`` instead."""
    row = _row(session, key)
    if row is None:
        session.add(ServerSetting(key=key, value=value, updated_at=utcnow()))
    else:
        row.value = value
        row.updated_at = utcnow()
    session.flush()


def delete_value(session: Session, key: str) -> None:
    row = _row(session, key)
    if row is not None:
        session.delete(row)
        session.flush()


# ---------------------------------------------------------------------------
# Typed accessors
# ---------------------------------------------------------------------------


def free_tier_limits(session: Session) -> dict[str, int]:
    raw = get_value(session, KEY_FREE_TIER_LIMITS)
    if not raw:
        return dict(_FREE_TIER_LIMITS_DEFAULT)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return dict(_FREE_TIER_LIMITS_DEFAULT)
    # Coerce: keys must be strings, values must be ints.
    result = dict(_FREE_TIER_LIMITS_DEFAULT)
    for key, value in (parsed or {}).items():
        if not isinstance(key, str):
            continue
        try:
            result[key] = int(value)
        except (TypeError, ValueError):
            continue
    return result


def set_free_tier_limits(session: Session, limits: dict[str, int]) -> None:
    cleaned = {str(key): int(value) for key, value in limits.items()}
    set_value(session, KEY_FREE_TIER_LIMITS, json.dumps(cleaned, sort_keys=True))


def openai_model(session: Session, settings: Settings | None = None) -> str:
    raw = (get_value(session, KEY_OPENAI_MODEL) or "").strip()
    if raw:
        return raw
    return (settings or get_settings()).ai_openai_model


def anthropic_model(session: Session, settings: Settings | None = None) -> str:
    raw = (get_value(session, KEY_ANTHROPIC_MODEL) or "").strip()
    if raw:
        return raw
    return (settings or get_settings()).ai_anthropic_model


def trial_mode_enabled(session: Session, settings: Settings | None = None) -> bool:
    raw = (get_value(session, KEY_TRIAL_MODE) or "").strip()
    if raw:
        return raw == "1"
    return bool((settings or get_settings()).trial_mode_enabled)


# ---------------------------------------------------------------------------
# Admin-side snapshot
# ---------------------------------------------------------------------------


def admin_snapshot(session: Session, settings: Settings | None = None) -> dict[str, Any]:
    """Single dict the admin UI hydrates from. Includes the effective
    value (db override or env default) plus a flag indicating which
    source supplied it so the operator can tell at a glance whether
    they're looking at a customized value or the baseline.
    """
    s = settings or get_settings()
    raw_limits = get_value(session, KEY_FREE_TIER_LIMITS)
    raw_openai = (get_value(session, KEY_OPENAI_MODEL) or "").strip()
    raw_anthropic = (get_value(session, KEY_ANTHROPIC_MODEL) or "").strip()
    raw_trial = (get_value(session, KEY_TRIAL_MODE) or "").strip()
    return {
        "free_tier_limits": {
            "value": free_tier_limits(session),
            "default": dict(_FREE_TIER_LIMITS_DEFAULT),
            "overridden": bool(raw_limits),
        },
        "ai_openai_model": {
            "value": raw_openai or s.ai_openai_model,
            "default": s.ai_openai_model,
            "overridden": bool(raw_openai),
        },
        "ai_anthropic_model": {
            "value": raw_anthropic or s.ai_anthropic_model,
            "default": s.ai_anthropic_model,
            "overridden": bool(raw_anthropic),
        },
        "trial_mode_enabled": {
            "value": trial_mode_enabled(session, s),
            "default": bool(s.trial_mode_enabled),
            "overridden": bool(raw_trial),
        },
    }
