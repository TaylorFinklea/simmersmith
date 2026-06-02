"""Tests for the Apple/Google web SSO layer that backs /oauth/authorize.

We deliberately don't exercise the live provider HTTP path (Apple's
token endpoint, Google's JWKS) — that would couple tests to network
availability and provider quirks. We DO exercise:

- State JWT mint + verify + tamper rejection + provider-mismatch
  rejection + expiry.
- Enablement gates that drive button visibility.
- Apple client_secret JWT structure (decoded with the test's own
  generated EC public key — proves ES256 signing path works).
- /oauth/sso/{apple,google}/start happy + missing-config + unknown-
  authorize-code paths via TestClient.
- Authorize page renders SSO buttons conditionally on env presence.
- Callback rejects garbage state JWTs.
"""
from __future__ import annotations

import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.config import get_settings
from app.services import sso


# ---------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _jwt_secret(monkeypatch) -> None:
    """State JWTs are signed with SIMMERSMITH_JWT_SECRET. Set it for
    every test — same pattern as test_oauth.py."""
    monkeypatch.setenv("SIMMERSMITH_JWT_SECRET", "test-sso-jwt-secret-32-bytes-mini")
    get_settings.cache_clear()


@pytest.fixture
def apple_env(monkeypatch) -> str:
    """Configure Apple SSO with a freshly-generated EC private key. The
    PEM is fed to SIMMERSMITH_APPLE_WEB_PRIVATE_KEY so mint_apple_client_secret
    has a real key to sign with. Returns the PEM so tests can re-decode
    minted tokens with the matching public key.
    """
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("ascii")
    monkeypatch.setenv("SIMMERSMITH_APPLE_WEB_SERVICE_ID", "app.simmersmith.web")
    monkeypatch.setenv("SIMMERSMITH_APPLE_WEB_TEAM_ID", "TEAM1234")
    monkeypatch.setenv("SIMMERSMITH_APPLE_WEB_KEY_ID", "KEYABCD")
    monkeypatch.setenv("SIMMERSMITH_APPLE_WEB_PRIVATE_KEY", pem)
    get_settings.cache_clear()
    return pem


@pytest.fixture
def google_env(monkeypatch) -> None:
    monkeypatch.setenv("SIMMERSMITH_GOOGLE_WEB_CLIENT_ID", "fake-google-client.apps.googleusercontent.com")
    monkeypatch.setenv("SIMMERSMITH_GOOGLE_WEB_CLIENT_SECRET", "fake-google-client-secret")
    get_settings.cache_clear()


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


def _begin_authorize(client, registered: dict) -> str:
    """Hit /oauth/authorize and return the pending authorize_code
    embedded in the rendered form."""
    import base64
    import hashlib
    import os

    verifier = base64.urlsafe_b64encode(os.urandom(32)).decode("ascii").rstrip("=")
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    response = client.get(
        "/oauth/authorize",
        params={
            "response_type": "code",
            "client_id": registered["client_id"],
            "redirect_uri": "https://claude.ai/oauth/callback",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": "client-state-123",
        },
    )
    assert response.status_code == 200, response.text
    import re

    match = re.search(r'name="code" value="([^"]+)"', response.text)
    assert match, "no authorize_code rendered in form"
    return match.group(1)


# ---------------------------------------------------------------------
# Enablement gates
# ---------------------------------------------------------------------


class TestEnablement:
    def test_apple_disabled_when_any_env_missing(self, monkeypatch) -> None:
        # Set only three of the four; should still be disabled.
        monkeypatch.setenv("SIMMERSMITH_APPLE_WEB_SERVICE_ID", "x")
        monkeypatch.setenv("SIMMERSMITH_APPLE_WEB_TEAM_ID", "y")
        monkeypatch.setenv("SIMMERSMITH_APPLE_WEB_KEY_ID", "z")
        get_settings.cache_clear()
        assert sso.apple_enabled(get_settings()) is False

    def test_apple_enabled_when_all_env_present(self, apple_env) -> None:
        assert sso.apple_enabled(get_settings()) is True

    def test_google_disabled_when_secret_missing(self, monkeypatch) -> None:
        monkeypatch.setenv("SIMMERSMITH_GOOGLE_WEB_CLIENT_ID", "x")
        get_settings.cache_clear()
        assert sso.google_enabled(get_settings()) is False

    def test_google_enabled_when_both_env_present(self, google_env) -> None:
        assert sso.google_enabled(get_settings()) is True


# ---------------------------------------------------------------------
# State JWT
# ---------------------------------------------------------------------


class TestStateJwt:
    def test_roundtrip_returns_authorize_code(self) -> None:
        settings = get_settings()
        state, nonce = sso.generate_state(authorize_code="abc123", provider="apple", settings=settings)
        assert nonce  # a fresh OIDC nonce is minted (M66)
        code, verified_nonce = sso.verify_state(state, expected_provider="apple", settings=settings)
        assert code == "abc123"
        assert verified_nonce == nonce

    def test_provider_mismatch_rejected(self) -> None:
        settings = get_settings()
        state, _ = sso.generate_state(authorize_code="abc", provider="apple", settings=settings)
        with pytest.raises(sso.SsoError, match="provider mismatch"):
            sso.verify_state(state, expected_provider="google", settings=settings)

    def test_tampered_state_rejected(self) -> None:
        settings = get_settings()
        state, _ = sso.generate_state(authorize_code="abc", provider="apple", settings=settings)
        # Flip a character in the JWT's payload segment.
        head, payload, sig = state.split(".")
        bad_payload = payload[:-1] + ("A" if payload[-1] != "A" else "B")
        tampered = f"{head}.{bad_payload}.{sig}"
        with pytest.raises(sso.SsoError):
            sso.verify_state(tampered, expected_provider="apple", settings=settings)

    def test_expired_state_rejected(self, monkeypatch) -> None:
        settings = get_settings()
        # Pin time backwards so the freshly minted state appears already-expired.
        real_time = time.time
        monkeypatch.setattr(sso.time, "time", lambda: real_time() - sso._STATE_TTL_SECONDS - 60)
        state, _ = sso.generate_state(authorize_code="abc", provider="apple", settings=settings)
        monkeypatch.undo()
        with pytest.raises(sso.SsoError, match="expired"):
            sso.verify_state(state, expected_provider="apple", settings=settings)

    def test_missing_jwt_secret_rejected(self, monkeypatch) -> None:
        monkeypatch.setenv("SIMMERSMITH_JWT_SECRET", "")
        get_settings.cache_clear()
        with pytest.raises(sso.SsoError, match="JWT_SECRET"):
            sso.generate_state(authorize_code="abc", provider="apple", settings=get_settings())

    def test_nonce_enforcement(self) -> None:
        # The id_token must echo the nonce we sent (M66). Empty expected
        # nonce (legacy state) skips the check.
        with pytest.raises(sso.SsoError, match="nonce mismatch"):
            sso._require_nonce({"nonce": "other"}, "expected")
        with pytest.raises(sso.SsoError, match="nonce mismatch"):
            sso._require_nonce({}, "expected")
        sso._require_nonce({"nonce": "expected"}, "expected")  # match → ok
        sso._require_nonce({}, "")  # legacy / no nonce sent → skipped


# ---------------------------------------------------------------------
# Apple client_secret minting
# ---------------------------------------------------------------------


class TestAppleClientSecret:
    def test_mints_valid_es256_jwt(self, apple_env) -> None:
        pem = apple_env  # private key PEM, returned by the fixture
        settings = get_settings()
        token = sso.mint_apple_client_secret(settings)

        private_key = serialization.load_pem_private_key(pem.encode("ascii"), password=None)
        public_key = private_key.public_key()
        claims = jwt.decode(
            token,
            public_key,
            algorithms=["ES256"],
            audience="https://appleid.apple.com",
        )
        assert claims["iss"] == "TEAM1234"
        assert claims["sub"] == "app.simmersmith.web"
        headers = jwt.get_unverified_header(token)
        assert headers["kid"] == "KEYABCD"
        assert headers["alg"] == "ES256"

    def test_raises_when_not_configured(self, monkeypatch) -> None:
        # apple_env fixture not used here; nothing is configured.
        with pytest.raises(sso.SsoError):
            sso.mint_apple_client_secret(get_settings())


# ---------------------------------------------------------------------
# Authorize page rendering — SSO buttons conditional on config
# ---------------------------------------------------------------------


class TestAuthorizePageRendering:
    def test_no_sso_env_renders_fallback_only(self, client) -> None:
        registered = _register_client(client)
        _begin_authorize(client, registered)  # also asserts the form renders
        # Re-render to assert button absence cleanly.
        import base64
        import hashlib
        import os

        verifier = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
        digest = hashlib.sha256(verifier.encode()).digest()
        challenge = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            },
        )
        assert response.status_code == 200
        assert "Sign in with Apple" not in response.text
        assert "Sign in with Google" not in response.text
        assert 'name="api_token"' in response.text

    def test_apple_env_renders_apple_button(self, client, apple_env) -> None:
        registered = _register_client(client)
        code = _begin_authorize(client, registered)
        # Re-render to check button presence
        import base64
        import hashlib
        import os

        verifier = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
        digest = hashlib.sha256(verifier.encode()).digest()
        challenge = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            },
        )
        assert "Sign in with Apple" in response.text
        assert "/oauth/sso/apple/start?code=" in response.text
        # No Google because google_env fixture not requested.
        assert "Sign in with Google" not in response.text
        del code  # silence unused

    def test_google_env_renders_google_button(self, client, google_env) -> None:
        registered = _register_client(client)
        _begin_authorize(client, registered)
        import base64
        import hashlib
        import os

        verifier = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
        digest = hashlib.sha256(verifier.encode()).digest()
        challenge = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        response = client.get(
            "/oauth/authorize",
            params={
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": "https://claude.ai/oauth/callback",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            },
        )
        assert "Sign in with Google" in response.text
        assert "/oauth/sso/google/start?code=" in response.text


# ---------------------------------------------------------------------
# /oauth/sso/{provider}/start endpoints
# ---------------------------------------------------------------------


class TestSsoStartEndpoints:
    def test_apple_start_redirects_to_appleid(self, client, apple_env) -> None:
        registered = _register_client(client)
        code = _begin_authorize(client, registered)
        response = client.get(f"/oauth/sso/apple/start?code={code}", follow_redirects=False)
        assert response.status_code == 302
        location = response.headers["location"]
        assert location.startswith("https://appleid.apple.com/auth/authorize?")
        assert "client_id=app.simmersmith.web" in location
        assert "response_mode=form_post" in location
        assert "state=" in location

    def test_apple_start_503_when_not_configured(self, client) -> None:
        registered = _register_client(client)
        code = _begin_authorize(client, registered)
        response = client.get(f"/oauth/sso/apple/start?code={code}")
        assert response.status_code == 503
        assert "not configured" in response.json()["detail"].lower()

    def test_google_start_redirects_to_google(self, client, google_env) -> None:
        registered = _register_client(client)
        code = _begin_authorize(client, registered)
        response = client.get(f"/oauth/sso/google/start?code={code}", follow_redirects=False)
        assert response.status_code == 302
        location = response.headers["location"]
        assert location.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
        assert "openid" in location
        assert "state=" in location

    def test_start_rejects_unknown_authorize_code(self, client, apple_env) -> None:
        response = client.get("/oauth/sso/apple/start?code=this-code-does-not-exist")
        assert response.status_code == 404


# ---------------------------------------------------------------------
# Callback endpoints — bad-state rejection (provider HTTP not exercised)
# ---------------------------------------------------------------------


class TestSsoCallbackRejection:
    def test_apple_callback_rejects_tampered_state(self, client, apple_env) -> None:
        response = client.post(
            "/oauth/sso/apple/callback",
            data={"code": "apple-side-code", "state": "not.a.real.jwt"},
            follow_redirects=False,
        )
        assert response.status_code == 400
        assert "invalid state" in response.json()["detail"].lower()

    def test_google_callback_rejects_tampered_state(self, client, google_env) -> None:
        response = client.get(
            "/oauth/sso/google/callback?code=google-side-code&state=not.a.real.jwt",
            follow_redirects=False,
        )
        assert response.status_code == 400
        assert "invalid state" in response.json()["detail"].lower()

    def test_callback_rejects_state_for_wrong_provider(self, client, apple_env) -> None:
        # State minted for Google can't be used at Apple's callback.
        settings = get_settings()
        google_state, _ = sso.generate_state(
            authorize_code="any", provider="google", settings=settings
        )
        response = client.post(
            "/oauth/sso/apple/callback",
            data={"code": "x", "state": google_state},
            follow_redirects=False,
        )
        assert response.status_code == 400
        assert "provider mismatch" in response.json()["detail"].lower()
