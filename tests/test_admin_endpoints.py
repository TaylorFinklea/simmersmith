"""Build 94 admin-site API tests."""
from __future__ import annotations

import json

from fastapi.testclient import TestClient

from app.config import Settings
from app.db import session_scope
from app.models import User, utcnow
from app.models._base import new_id
from app.services.entitlements import (
    ACTION_AI_GENERATE,
    ACTION_RECIPE_IMPORT,
    increment_usage,
)


def _seed_user(email: str = "admin-probe@test.com") -> str:
    user_id = new_id()
    with session_scope() as session:
        session.add(
            User(id=user_id, email=email, display_name="Probe User", created_at=utcnow())
        )
    return user_id


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_admin_usage_summary_aggregates_per_user_and_action(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("usage-a@test.com")
    user_b = _seed_user("usage-b@test.com")
    with session_scope() as session:
        increment_usage(session, user_id, ACTION_AI_GENERATE)
        increment_usage(session, user_id, ACTION_AI_GENERATE)
        increment_usage(session, user_id, ACTION_RECIPE_IMPORT)
        increment_usage(session, user_b, ACTION_AI_GENERATE)

    response = client.get(
        "/api/admin/usage",
        headers=_headers(settings_with_api_token.api_token),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["totals"][ACTION_AI_GENERATE] == 3
    assert body["totals"][ACTION_RECIPE_IMPORT] == 1
    # Sorted by total desc; user A has 3, user B has 1.
    top_emails = [row["email"] for row in body["by_user"]]
    assert top_emails == ["usage-a@test.com", "usage-b@test.com"]


def test_admin_users_lists_every_user_with_monthly_total(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("lister@test.com")
    with session_scope() as session:
        increment_usage(session, user_id, ACTION_AI_GENERATE)

    response = client.get(
        "/api/admin/users",
        headers=_headers(settings_with_api_token.api_token),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    found = next(user for user in body["users"] if user["email"] == "lister@test.com")
    assert found["monthly_usage"] == 1


def test_admin_settings_round_trips_free_tier_limits(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    snapshot = client.get(
        "/api/admin/settings",
        headers=_headers(settings_with_api_token.api_token),
    ).json()
    assert snapshot["free_tier_limits"]["overridden"] is False

    response = client.patch(
        "/api/admin/settings",
        headers=_headers(settings_with_api_token.api_token),
        json={"free_tier_limits": {"ai_generate": 99, "pricing_fetch": 50}},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["free_tier_limits"]["overridden"] is True
    assert body["free_tier_limits"]["value"]["ai_generate"] == 99
    # Untouched defaults still flow through.
    assert body["free_tier_limits"]["value"]["recipe_import"] == 5


def test_admin_settings_patch_clears_back_to_default_when_null(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    client.patch(
        "/api/admin/settings",
        headers=_headers(settings_with_api_token.api_token),
        json={"ai_openai_model": "gpt-test-override"},
    )
    client.patch(
        "/api/admin/settings",
        headers=_headers(settings_with_api_token.api_token),
        json={"ai_openai_model": None},
    )
    snapshot = client.get(
        "/api/admin/settings",
        headers=_headers(settings_with_api_token.api_token),
    ).json()
    assert snapshot["ai_openai_model"]["overridden"] is False
    # Default falls through to the env-driven config value.
    assert snapshot["ai_openai_model"]["value"] == snapshot["ai_openai_model"]["default"]


def test_admin_settings_requires_bearer(client: TestClient, settings_with_api_token: Settings) -> None:
    assert client.get("/api/admin/settings").status_code == 403
    assert client.patch("/api/admin/settings", json={"trial_mode_enabled": True}).status_code == 403


def test_free_tier_limit_override_lives_in_db(client: TestClient, settings_with_api_token: Settings) -> None:
    """The DB override actually changes what ``current_usage`` reports —
    not just the admin snapshot."""
    user_id = _seed_user("limit-probe@test.com")
    response = client.patch(
        "/api/admin/settings",
        headers=_headers(settings_with_api_token.api_token),
        json={"free_tier_limits": {"ai_generate": 42}},
    )
    assert response.status_code == 200

    from app.services.entitlements import current_usage

    with session_scope() as session:
        summary = current_usage(session, user_id, ACTION_AI_GENERATE)
    assert summary.limit == 42

    # Strip the override; limit returns to the hard-coded default (1).
    _ = json.dumps  # silence unused-import warnings if any
    client.patch(
        "/api/admin/settings",
        headers=_headers(settings_with_api_token.api_token),
        json={"free_tier_limits": None},
    )
    with session_scope() as session:
        summary = current_usage(session, user_id, ACTION_AI_GENERATE)
    assert summary.limit == 1
