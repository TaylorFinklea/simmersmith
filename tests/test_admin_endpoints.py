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


def test_admin_user_detail_returns_usage_and_subscription(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("detail@test.com")
    with session_scope() as session:
        increment_usage(session, user_id, ACTION_AI_GENERATE)
        increment_usage(session, user_id, ACTION_RECIPE_IMPORT)
        increment_usage(session, user_id, ACTION_RECIPE_IMPORT)

    response = client.get(
        f"/api/admin/users/{user_id}",
        headers=_headers(settings_with_api_token.api_token),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["user"]["email"] == "detail@test.com"
    assert body["subscription"] is None
    assert body["usage"]["this_period"]["totals"][ACTION_AI_GENERATE] == 1
    assert body["usage"]["this_period"]["totals"][ACTION_RECIPE_IMPORT] == 2
    assert body["usage"]["this_period"]["total"] == 3
    # Default rates: 0.012 * 1 + 0.004 * 2 = 0.020
    assert body["usage"]["this_period"]["estimated_cost_usd"] == 0.02
    assert body["inventory"]["recipes"] == 0
    assert body["inventory"]["active_push_devices"] == 0


def test_admin_user_detail_404_for_unknown_user(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    response = client.get(
        "/api/admin/users/does-not-exist",
        headers=_headers(settings_with_api_token.api_token),
    )
    assert response.status_code == 404


def test_admin_user_detail_requires_bearer(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("noauth@test.com")
    assert client.get(f"/api/admin/users/{user_id}").status_code == 403


def test_admin_grant_pro_creates_admin_subscription_and_flips_is_pro(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    from app.services.entitlements import is_pro

    user_id = _seed_user("grant@test.com")
    response = client.post(
        f"/api/admin/users/{user_id}/subscription",
        headers=_headers(settings_with_api_token.api_token),
        json={"action": "grant_pro", "until": "2099-12-31", "note": "beta reward"},
    )
    assert response.status_code == 200, response.text
    sub = response.json()["subscription"]
    assert sub["status"] == "active"
    assert sub["source"] == "admin"
    assert sub["admin_note"] == "beta reward"

    with session_scope() as session:
        assert is_pro(session, user_id) is True


def test_admin_grant_pro_idempotent_extends_existing_row(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("extend@test.com")
    client.post(
        f"/api/admin/users/{user_id}/subscription",
        headers=_headers(settings_with_api_token.api_token),
        json={"action": "grant_pro", "until": "2099-01-01", "note": "first"},
    )
    second = client.post(
        f"/api/admin/users/{user_id}/subscription",
        headers=_headers(settings_with_api_token.api_token),
        json={"action": "grant_pro", "until": "2099-12-31", "note": "second"},
    )
    assert second.status_code == 200, second.text
    sub = second.json()["subscription"]
    assert sub["current_period_ends_at"].startswith("2099-12-31")
    assert sub["admin_note"] == "second"


def test_admin_revoke_marks_subscription_revoked(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    from app.services.entitlements import is_pro

    user_id = _seed_user("revoke@test.com")
    client.post(
        f"/api/admin/users/{user_id}/subscription",
        headers=_headers(settings_with_api_token.api_token),
        json={"action": "grant_pro", "until": "2099-12-31"},
    )
    response = client.post(
        f"/api/admin/users/{user_id}/subscription",
        headers=_headers(settings_with_api_token.api_token),
        json={"action": "revoke"},
    )
    assert response.status_code == 200, response.text
    sub = response.json()["subscription"]
    assert sub["status"] == "revoked"
    assert sub["cancelled_at"] is not None

    with session_scope() as session:
        assert is_pro(session, user_id) is False


def test_admin_revoke_404_when_no_existing_subscription(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("ghost@test.com")
    response = client.post(
        f"/api/admin/users/{user_id}/subscription",
        headers=_headers(settings_with_api_token.api_token),
        json={"action": "revoke"},
    )
    assert response.status_code == 404


def test_admin_grant_pro_rejects_past_until(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("past@test.com")
    response = client.post(
        f"/api/admin/users/{user_id}/subscription",
        headers=_headers(settings_with_api_token.api_token),
        json={"action": "grant_pro", "until": "2000-01-01"},
    )
    assert response.status_code == 400


def test_admin_subscription_override_requires_bearer(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("anon@test.com")
    response = client.post(
        f"/api/admin/users/{user_id}/subscription",
        json={"action": "grant_pro", "until": "2099-12-31"},
    )
    assert response.status_code == 403


def test_admin_usage_includes_cost_estimate(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    user_id = _seed_user("costs@test.com")
    with session_scope() as session:
        increment_usage(session, user_id, ACTION_AI_GENERATE)
        increment_usage(session, user_id, ACTION_AI_GENERATE)
    response = client.get(
        "/api/admin/usage",
        headers=_headers(settings_with_api_token.api_token),
    )
    body = response.json()
    # Two ai_generate * default 0.012 = 0.024
    assert body["estimated_cost_usd"] == 0.024
    user_row = next(row for row in body["by_user"] if row["email"] == "costs@test.com")
    assert user_row["estimated_cost_usd"] == 0.024


def test_admin_settings_round_trips_usage_cost_rates(
    client: TestClient, settings_with_api_token: Settings
) -> None:
    response = client.patch(
        "/api/admin/settings",
        headers=_headers(settings_with_api_token.api_token),
        json={"usage_cost_usd": {"ai_generate": 0.05}},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["usage_cost_usd"]["overridden"] is True
    assert body["usage_cost_usd"]["value"]["ai_generate"] == 0.05
    # Unspecified actions retain their defaults.
    assert body["usage_cost_usd"]["value"]["recipe_import"] == 0.004


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
