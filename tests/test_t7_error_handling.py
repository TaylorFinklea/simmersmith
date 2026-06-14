"""T7 — observability & error-handling hardening.

Covers the arch-T7 findings: provider transport/parse failures must not escape as
bare 500s, unhandled errors must be logged + returned as a generic body (no
internals leaked), a DB blip maps to 503, and logging is actually configured.
"""
from __future__ import annotations

from unittest.mock import MagicMock

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy.exc import OperationalError

from app.config import get_settings
from app.main import app
from app.services import week_planner


def _openai_settings(monkeypatch):
    monkeypatch.setenv("SIMMERSMITH_AI_OPENAI_API_KEY", "sk-test-key")
    monkeypatch.setenv("SIMMERSMITH_AI_MCP_ENABLED", "false")
    get_settings.cache_clear()
    return get_settings()


def _new_week(client: TestClient, week_start: str) -> str:
    body = client.post("/api/weeks", json={"week_start": week_start, "notes": ""}).json()
    return body.get("week_id") or body["id"]


# ── _call_ai_provider wraps transport/shape failures ────────────────


def test_call_ai_provider_wraps_timeout(monkeypatch) -> None:
    settings = _openai_settings(monkeypatch)

    def _boom(self, *a, **k):
        raise httpx.ReadTimeout("read operation timed out")

    monkeypatch.setattr("httpx.Client.post", _boom)
    with pytest.raises(week_planner.AIProviderError) as ei:
        week_planner._call_ai_provider(
            settings=settings, user_settings={}, system_prompt="s", user_prompt="u"
        )
    # Clean, retryable message — never the upstream URL.
    assert "openai.com" not in str(ei.value)
    assert "http" not in str(ei.value).lower()


def test_call_ai_provider_wraps_bad_shape(monkeypatch) -> None:
    settings = _openai_settings(monkeypatch)

    resp = MagicMock()
    resp.raise_for_status.return_value = None
    resp.json.return_value = {}  # missing "choices" -> KeyError

    monkeypatch.setattr("httpx.Client.post", lambda self, *a, **k: resp)
    with pytest.raises(week_planner.AIProviderError):
        week_planner._call_ai_provider(
            settings=settings, user_settings={}, system_prompt="s", user_prompt="u"
        )


# ── generate route maps AIProviderError -> 503, not 500/422 ─────────


def test_generate_route_maps_ai_provider_error_to_503(client, monkeypatch) -> None:
    def _boom(**k):
        raise week_planner.AIProviderError(
            "The meal-planning AI is temporarily unavailable. Please try again."
        )

    monkeypatch.setattr("app.services.week_planner.generate_week_plan", _boom)
    week_id = _new_week(client, "2026-09-07")
    r = client.post(f"/api/weeks/{week_id}/generate", json={"prompt": ""})
    assert r.status_code == 503
    detail = r.json()["detail"].lower()
    assert "temporarily unavailable" in detail
    assert "http" not in detail  # no leaked URL


# ── global handlers: generic 500 (no leak) + OperationalError -> 503 ─


def test_unhandled_exception_returns_generic_500(monkeypatch) -> None:
    def _boom(*a, **k):
        raise Exception("boomSecret /internal/leak path")

    monkeypatch.setattr("app.api.weeks.list_weeks", _boom)
    # raise_server_exceptions=False so the ServerErrorMiddleware response is
    # returned to us instead of re-raised.
    with TestClient(app, raise_server_exceptions=False) as c:
        r = c.get("/api/weeks")
    assert r.status_code == 500
    assert r.json()["detail"] == "Internal server error."
    assert "boomSecret" not in r.text
    assert "leak" not in r.text


def test_operational_error_maps_to_503(client, monkeypatch) -> None:
    def _boom(*a, **k):
        raise OperationalError("SELECT 1", {}, Exception("database is down"))

    monkeypatch.setattr("app.api.weeks.list_weeks", _boom)
    r = client.get("/api/weeks")
    assert r.status_code == 503
    assert r.headers.get("Retry-After") == "5"
    assert "database is down" not in r.text  # raw cause not leaked


# ── readiness probe + logging config ────────────────────────────────


def test_readiness_probe_ok(client) -> None:
    r = client.get("/api/health/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_configure_logging_installs_root_stdout_handler() -> None:
    # pytest's own logging plugin owns the root level during a run, so assert on
    # the function's effect directly rather than the ambient session state.
    import logging
    import sys

    from app.main import configure_logging

    configure_logging()
    root = logging.getLogger()
    assert root.level == logging.INFO
    assert any(
        isinstance(h, logging.StreamHandler) and getattr(h, "stream", None) is sys.stdout
        for h in root.handlers
    )
