"""Web SSO for the OAuth authorize page.

The OAuth surface in `app/services/oauth.py` handles RFC 6749 / 8414 /
7591 / PKCE — it doesn't care *how* the human at `/oauth/authorize`
proves who they are. This module is the optional web user-auth
provider: Apple / Google redirect-flow Sign-In that finds-or-creates
the `User` row and hands the resulting `user_id` back to oauth.py's
authorize approval.

Distinct from `app/auth.py` (iOS auth):
- iOS sends a native identity token via `POST /api/auth/{apple,google}`.
- Web does the OAuth redirect dance and we exchange a `code` for the
  identity token ourselves.
- Different OAuth client per provider, so different `audience` claims.

Apple's quirk: `client_secret` is itself a fresh ES256-signed JWT,
minted per token-exchange using the .p8 key in
`SIMMERSMITH_APPLE_WEB_PRIVATE_KEY`. We never store a long-lived
secret.

State is a short-lived signed JWT carrying the pending OAuth
authorize-request code — stateless, no extra DB table.
"""
from __future__ import annotations

import logging
import time
from secrets import token_urlsafe
from typing import Literal
from urllib.parse import urlencode

import httpx
import jwt
from jwt import PyJWKClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models._base import utcnow
from app.models.user import User


log = logging.getLogger(__name__)


# Window for the provider round-trip — long enough for a human to get
# through the Apple/Google account pick + consent screens, still
# bounded so a stolen redirect URL can't be replayed indefinitely.
_STATE_TTL_SECONDS = 1800

# Apple requires a fresh JWT-as-client-secret per token exchange.
# Keep it short to limit replay if the token endpoint logs it.
_APPLE_CLIENT_SECRET_TTL_SECONDS = 300

APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
APPLE_AUTHORIZE_URL = "https://appleid.apple.com/auth/authorize"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"


class SsoError(Exception):
    """SSO-flow failure. Message is public-safe (no secret material)."""


_apple_jwks: PyJWKClient | None = None
_google_jwks: PyJWKClient | None = None


def _apple_jwks_client() -> PyJWKClient:
    global _apple_jwks
    if _apple_jwks is None:
        _apple_jwks = PyJWKClient(APPLE_JWKS_URL)
    return _apple_jwks


def _google_jwks_client() -> PyJWKClient:
    global _google_jwks
    if _google_jwks is None:
        _google_jwks = PyJWKClient(GOOGLE_JWKS_URL)
    return _google_jwks


# ---------------------------------------------------------------------
# Enablement flags — drive button visibility on the authorize page
# ---------------------------------------------------------------------

def apple_enabled(settings: Settings) -> bool:
    return bool(
        settings.apple_web_service_id
        and settings.apple_web_team_id
        and settings.apple_web_key_id
        and settings.apple_web_private_key
    )


def google_enabled(settings: Settings) -> bool:
    return bool(settings.google_web_client_id and settings.google_web_client_secret)


# ---------------------------------------------------------------------
# State JWT — carries the pending authorize_code across the provider hop
# ---------------------------------------------------------------------

Provider = Literal["apple", "google"]


def generate_state(*, authorize_code: str, provider: Provider, settings: Settings) -> str:
    if not settings.jwt_secret:
        raise SsoError("Server has no SIMMERSMITH_JWT_SECRET configured")
    now = int(time.time())
    payload = {
        "authorize_code": authorize_code,
        "provider": provider,
        "iat": now,
        "exp": now + _STATE_TTL_SECONDS,
        "jti": token_urlsafe(8),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


def verify_state(state: str, *, expected_provider: Provider, settings: Settings) -> str:
    """Decode the state JWT, enforce provider match, return the original
    OAuth authorize-request code. Raises `SsoError` on tampering,
    expiry, or cross-provider replay."""
    if not settings.jwt_secret:
        raise SsoError("Server has no SIMMERSMITH_JWT_SECRET configured")
    try:
        payload = jwt.decode(state, settings.jwt_secret, algorithms=["HS256"])
    except jwt.ExpiredSignatureError as exc:
        raise SsoError("state expired") from exc
    except jwt.InvalidTokenError as exc:
        raise SsoError(f"invalid state: {exc}") from exc
    if payload.get("provider") != expected_provider:
        raise SsoError("state provider mismatch")
    code = payload.get("authorize_code")
    if not code or not isinstance(code, str):
        raise SsoError("state missing authorize_code")
    return code


# ---------------------------------------------------------------------
# Provider authorize URL builders
# ---------------------------------------------------------------------

def apple_authorize_url(*, state: str, callback_url: str, settings: Settings) -> str:
    if not apple_enabled(settings):
        raise SsoError("Apple Sign In for Web not configured")
    params = {
        "client_id": settings.apple_web_service_id,
        "redirect_uri": callback_url,
        "response_type": "code",
        # Apple recommends form_post for web — POSTs code+state to the
        # redirect_uri rather than putting them in the URL fragment.
        "response_mode": "form_post",
        "scope": "name email",
        "state": state,
    }
    return f"{APPLE_AUTHORIZE_URL}?{urlencode(params)}"


def google_authorize_url(*, state: str, callback_url: str, settings: Settings) -> str:
    if not google_enabled(settings):
        raise SsoError("Google Sign In for Web not configured")
    params = {
        "client_id": settings.google_web_client_id,
        "redirect_uri": callback_url,
        "response_type": "code",
        "scope": "openid email profile",
        "state": state,
        # `select_account` so users picking which Google to sign in with
        # don't get auto-logged-in as the last-used one.
        "prompt": "select_account",
    }
    return f"{GOOGLE_AUTHORIZE_URL}?{urlencode(params)}"


# ---------------------------------------------------------------------
# Apple client_secret minting (ES256 JWT)
# ---------------------------------------------------------------------

def mint_apple_client_secret(settings: Settings) -> str:
    """Apple's token-exchange step authenticates the client with a
    fresh ES256-signed JWT. The .p8 private key lives in
    SIMMERSMITH_APPLE_WEB_PRIVATE_KEY (PEM, multi-line)."""
    if not apple_enabled(settings):
        raise SsoError("Apple Sign In for Web not configured")
    now = int(time.time())
    payload = {
        "iss": settings.apple_web_team_id,
        "iat": now,
        "exp": now + _APPLE_CLIENT_SECRET_TTL_SECONDS,
        "aud": "https://appleid.apple.com",
        "sub": settings.apple_web_service_id,
    }
    headers = {"kid": settings.apple_web_key_id, "alg": "ES256"}
    return jwt.encode(
        payload,
        settings.apple_web_private_key,
        algorithm="ES256",
        headers=headers,
    )


# ---------------------------------------------------------------------
# Provider code exchange
# ---------------------------------------------------------------------

def exchange_apple_code(*, code: str, callback_url: str, settings: Settings) -> dict:
    """POST to Apple's token endpoint, verify the returned id_token
    against the web Service ID audience, return claims."""
    client_secret = mint_apple_client_secret(settings)
    with httpx.Client(timeout=10.0) as client:
        resp = client.post(
            APPLE_TOKEN_URL,
            data={
                "client_id": settings.apple_web_service_id,
                "client_secret": client_secret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": callback_url,
            },
        )
    if resp.status_code != 200:
        log.warning("apple token exchange failed: %s %s", resp.status_code, resp.text)
        raise SsoError("apple token exchange failed")
    body = resp.json()
    id_token = body.get("id_token")
    if not id_token:
        raise SsoError("apple response missing id_token")
    return _verify_apple_id_token_web(id_token, settings)


def exchange_google_code(*, code: str, callback_url: str, settings: Settings) -> dict:
    """POST to Google's token endpoint, verify the returned id_token
    against the web OAuth client_id audience, return claims."""
    with httpx.Client(timeout=10.0) as client:
        resp = client.post(
            GOOGLE_TOKEN_URL,
            data={
                "client_id": settings.google_web_client_id,
                "client_secret": settings.google_web_client_secret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": callback_url,
            },
        )
    if resp.status_code != 200:
        log.warning("google token exchange failed: %s %s", resp.status_code, resp.text)
        raise SsoError("google token exchange failed")
    body = resp.json()
    id_token = body.get("id_token")
    if not id_token:
        raise SsoError("google response missing id_token")
    return _verify_google_id_token_web(id_token, settings)


def _verify_apple_id_token_web(token: str, settings: Settings) -> dict:
    try:
        signing_key = _apple_jwks_client().get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.apple_web_service_id,
            issuer="https://appleid.apple.com",
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
            leeway=30,
        )
    except jwt.InvalidTokenError as exc:
        raise SsoError(f"invalid Apple id_token: {exc}") from exc
    return claims


def _verify_google_id_token_web(token: str, settings: Settings) -> dict:
    try:
        signing_key = _google_jwks_client().get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.google_web_client_id,
            # Google issues from either, depending on the moon phase
            issuer=["https://accounts.google.com", "accounts.google.com"],
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
            leeway=30,
        )
    except jwt.InvalidTokenError as exc:
        raise SsoError(f"invalid Google id_token: {exc}") from exc
    return claims


# ---------------------------------------------------------------------
# Find-or-create user from verified provider claims
# ---------------------------------------------------------------------

def find_or_create_apple_user(session: Session, claims: dict) -> User:
    """Find existing user by `apple_sub`, or create one. Same
    precedent as `app/api/auth.py::auth_apple` so signing in via web
    matches the iOS account when the Apple ID is the same."""
    apple_sub = claims["sub"]
    user = session.scalars(select(User).where(User.apple_sub == apple_sub)).one_or_none()
    if user is None:
        user = User(
            apple_sub=apple_sub,
            email=claims.get("email", ""),
            created_at=utcnow(),
        )
        session.add(user)
        session.flush()
    return user


def find_or_create_google_user(session: Session, claims: dict) -> User:
    """Find existing user by `google_sub`, or create one. Same
    precedent as `app/api/auth.py::auth_google`."""
    google_sub = claims["sub"]
    user = session.scalars(select(User).where(User.google_sub == google_sub)).one_or_none()
    if user is None:
        user = User(
            google_sub=google_sub,
            email=claims.get("email", ""),
            display_name=claims.get("name", ""),
            created_at=utcnow(),
        )
        session.add(user)
        session.flush()
    return user
