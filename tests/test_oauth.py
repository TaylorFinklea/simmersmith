"""Tests for the OAuth 2.1 + PKCE flow backing the remote MCP endpoint.

Covers:
- Metadata document shape (RFC 8414).
- Dynamic Client Registration round-trip (RFC 7591).
- /oauth/authorize input validation + HTML render.
- /oauth/authorize/approve bearer-token user-auth.
- /oauth/token PKCE verification + single-use code semantics + JWT issuance.
- ``verify_mcp_access_token`` decoder (aud check, expiry, missing claims).
"""
from __future__ import annotations

import base64
import hashlib
import os
import time
from datetime import datetime, timezone

import jwt
import pytest

from app.config import get_settings
from app.services.oauth import (
    MCP_TOKEN_AUDIENCE,
    OAuthError,
    issue_mcp_access_token,
    verify_mcp_access_token,
)


@pytest.fixture(autouse=True)
def _jwt_secret(monkeypatch) -> None:
    """All OAuth tests need a configured JWT secret — the access tokens
    and the server-side verifier both depend on it. The default test
    environment leaves ``SIMMERSMITH_JWT_SECRET`` unset."""
    monkeypatch.setenv("SIMMERSMITH_JWT_SECRET", "test-oauth-jwt-secret-32-bytes!!")
    get_settings.cache_clear()


@pytest.fixture
def admin_token(monkeypatch) -> str:
    """Set SIMMERSMITH_API_TOKEN to a known value and return it.

    The OAuth authorize-approve flow validates the form-posted
    ``api_token`` against ``settings.api_token``. The conftest
    fixture ``settings_with_api_token`` does the same monkeypatch but
    yields a Settings object; we just need the string here.
    """
    token = "test-admin-token"
    monkeypatch.setenv("SIMMERSMITH_API_TOKEN", token)
    get_settings.cache_clear()
    return token


def _pkce_pair() -> tuple[str, str]:
    """Return (code_verifier, code_challenge_s256)."""
    verifier = base64.urlsafe_b64encode(os.urandom(32)).decode("ascii").rstrip("=")
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return verifier, challenge


def _register_client(client) -> dict:
    response = client.post(
        "/oauth/register",
        json={
            "client_name": "Claude.ai test",
            "redirect_uris": ["https://claude.ai/oauth/callback"],
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


class TestMetadata:
    def test_metadata_endpoint_exposes_required_fields(self, client) -> None:
        response = client.get("/.well-known/oauth-authorization-server")
        assert response.status_code == 200
        body = response.json()
        for key in (
            "issuer",
            "authorization_endpoint",
            "token_endpoint",
            "registration_endpoint",
            "response_types_supported",
            "grant_types_supported",
            "code_challenge_methods_supported",
            "token_endpoint_auth_methods_supported",
        ):
            assert key in body, f"missing {key}"
        assert body["response_types_supported"] == ["code"]
        assert body["grant_types_supported"] == ["authorization_code"]
        assert body["code_challenge_methods_supported"] == ["S256"]
        # Public client + PKCE means token endpoint auth is "none".
        assert "none" in body["token_endpoint_auth_methods_supported"]
        assert body["authorization_endpoint"].endswith("/oauth/authorize")
        assert body["token_endpoint"].endswith("/oauth/token")


class TestDynamicClientRegistration:
    def test_register_creates_client(self, client) -> None:
        registered = _register_client(client)
        assert registered["client_name"] == "Claude.ai test"
        assert registered["redirect_uris"] == ["https://claude.ai/oauth/callback"]
        assert registered["token_endpoint_auth_method"] == "none"
        assert "client_id" in registered and len(registered["client_id"]) >= 16

    def test_register_rejects_missing_redirect_uris(self, client) -> None:
        response = client.post(
            "/oauth/register",
            json={"client_name": "Claude.ai", "redirect_uris": []},
        )
        assert response.status_code == 400
        body = response.json()["detail"]
        assert body["error"] in {"invalid_redirect_uri", "invalid_request"}


class TestAuthorizeEndpoint:
    def test_authorize_returns_html_form(self, client) -> None:
        registered = _register_client(client)
        _, challenge = _pkce_pair()
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": "xyz",
            },
        )
        assert response.status_code == 200
        assert "text/html" in response.headers["content-type"]
        # The hidden ``code`` is the pending-request key. We don't
        # assert exact value, just shape.
        assert 'name="code"' in response.text
        assert "Claude.ai test" in response.text

    def test_authorize_rejects_unknown_client_id(self, client) -> None:
        _, challenge = _pkce_pair()
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": "this-does-not-exist",
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            },
        )
        assert response.status_code == 400
        assert response.json()["detail"]["error"] == "invalid_client"

    def test_authorize_rejects_unregistered_redirect_uri(self, client) -> None:
        registered = _register_client(client)
        _, challenge = _pkce_pair()
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": "https://evil.example/cb",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            },
        )
        assert response.status_code == 400
        assert response.json()["detail"]["error"] == "invalid_request"

    def test_authorize_rejects_missing_pkce(self, client) -> None:
        registered = _register_client(client)
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_challenge": "",
                "code_challenge_method": "S256",
            },
        )
        assert response.status_code == 400

    def test_authorize_rejects_plain_challenge_method(self, client) -> None:
        registered = _register_client(client)
        _, challenge = _pkce_pair()
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_challenge": challenge,
                "code_challenge_method": "plain",
            },
        )
        assert response.status_code == 400


class TestEndToEndFlow:
    def _initiate(self, client) -> tuple[dict, str, str, str]:
        registered = _register_client(client)
        verifier, challenge = _pkce_pair()
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": "abc",
            },
        )
        assert response.status_code == 200
        # Extract code from the rendered HTML form.
        import re

        match = re.search(r'name="code" value="([^"]+)"', response.text)
        assert match, "code not found in authorize page"
        return registered, verifier, challenge, match.group(1)

    def test_full_authorization_code_flow(
        self, client, admin_token: str
    ) -> None:
        registered, verifier, _, code = self._initiate(client)

        # 1. Approve with correct API token.
        approve = client.post(
            "/oauth/authorize/approve",
            data={"code": code, "api_token": admin_token},
            follow_redirects=False,
        )
        assert approve.status_code == 302
        location = approve.headers["location"]
        assert location.startswith("https://claude.ai/oauth/callback")
        assert f"code={code}" in location
        assert "state=abc" in location

        # 2. Exchange the code for an access token.
        token_response = client.post(
            "/oauth/token",
            data={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_verifier": verifier,
            },
        )
        assert token_response.status_code == 200, token_response.text
        token_body = token_response.json()
        assert token_body["token_type"] == "Bearer"
        assert token_body["expires_in"] > 0
        assert isinstance(token_body["access_token"], str)
        assert len(token_body["access_token"]) > 100

        # 3. Verify the token decodes with aud="mcp".
        settings = get_settings()
        verified = verify_mcp_access_token(token_body["access_token"], settings)
        assert verified.user_id == settings.local_user_id
        assert verified.client_id == registered["client_id"]

    def test_approve_rejects_wrong_api_token(self, client, admin_token: str) -> None:
        # admin_token fixture ensures SIMMERSMITH_API_TOKEN is set; we
        # post a *different* value to confirm the mismatch is rejected.
        del admin_token  # only need the side-effect of setting the env var
        _, _, _, code = self._initiate(client)
        response = client.post(
            "/oauth/authorize/approve",
            data={"code": code, "api_token": "definitely-wrong"},
        )
        # Re-renders the authorize page with the error inline.
        assert response.status_code == 200
        assert "didn't match" in response.text or "did not match" in response.text

    def test_token_rejects_wrong_verifier(self, client, admin_token: str) -> None:
        registered, _, _, code = self._initiate(client)
        client.post(
            "/oauth/authorize/approve",
            data={"code": code, "api_token": admin_token},
            follow_redirects=False,
        )
        response = client.post(
            "/oauth/token",
            data={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_verifier": "wrong-verifier-totally",
            },
        )
        assert response.status_code == 400
        assert response.json()["error"] == "invalid_grant"

    def test_token_rejects_replay(self, client, admin_token: str) -> None:
        """A successfully-exchanged code cannot be reused."""
        registered, verifier, _, code = self._initiate(client)
        client.post(
            "/oauth/authorize/approve",
            data={"code": code, "api_token": admin_token},
            follow_redirects=False,
        )
        first = client.post(
            "/oauth/token",
            data={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_verifier": verifier,
            },
        )
        assert first.status_code == 200
        # Second attempt with the same code.
        second = client.post(
            "/oauth/token",
            data={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_verifier": verifier,
            },
        )
        assert second.status_code == 400
        assert second.json()["error"] == "invalid_grant"

    def test_token_rejects_unapproved_code(self, client, admin_token: str) -> None:
        """If the authorize page never approved, /oauth/token must reject."""
        registered, verifier, _, code = self._initiate(client)
        # No /oauth/authorize/approve call.
        response = client.post(
            "/oauth/token",
            data={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_verifier": verifier,
            },
        )
        assert response.status_code == 400
        assert response.json()["error"] == "invalid_grant"


class TestAccessTokenVerification:
    def test_round_trip(self) -> None:
        settings = get_settings()
        token = issue_mcp_access_token(
            user_id="user-a",
            client_id="client-z",
            settings=settings,
            scope="mcp",
        )
        verified = verify_mcp_access_token(token, settings)
        assert verified.user_id == "user-a"
        assert verified.client_id == "client-z"
        assert verified.scope == "mcp"

    def test_rejects_session_jwt_replay(self) -> None:
        """A session JWT (no ``aud="mcp"``) must NOT verify as an MCP token."""
        settings = get_settings()
        # Build a session-style JWT (no aud).
        now = datetime.now(timezone.utc)
        payload = {
            "sub": "user-a",
            "iat": now,
            "exp": now.timestamp() + 3600,
        }
        session_token = jwt.encode(
            payload, settings.jwt_secret, algorithm=settings.jwt_algorithm
        )
        try:
            verify_mcp_access_token(session_token, settings)
        except OAuthError as err:
            assert err.code == "invalid_token"
        else:
            raise AssertionError("Session JWT should not verify as MCP token")

    def test_rejects_expired_token(self) -> None:
        settings = get_settings()
        now = datetime.now(timezone.utc)
        payload = {
            "sub": "user-a",
            "aud": MCP_TOKEN_AUDIENCE,
            "client_id": "client-z",
            "iat": now.timestamp() - 7200,
            "exp": now.timestamp() - 60,  # expired one minute ago
        }
        expired = jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)
        try:
            verify_mcp_access_token(expired, settings)
        except OAuthError as err:
            assert err.code == "invalid_token"
        else:
            raise AssertionError("Expired token should not verify")

    def test_rejects_token_with_wrong_secret(self) -> None:
        settings = get_settings()
        now = datetime.now(timezone.utc)
        payload = {
            "sub": "user-a",
            "aud": MCP_TOKEN_AUDIENCE,
            "client_id": "client-z",
            "iat": now,
            "exp": int(time.time()) + 3600,
        }
        bad = jwt.encode(payload, "this-is-not-our-secret-at-all-32+bytes", algorithm=settings.jwt_algorithm)
        try:
            verify_mcp_access_token(bad, settings)
        except OAuthError as err:
            assert err.code == "invalid_token"
        else:
            raise AssertionError("Token with wrong secret should not verify")
