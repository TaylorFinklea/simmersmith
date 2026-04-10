"""Authentication: Apple/Google Sign-In + session JWT + legacy bearer.

Auth flow:
  1. iOS does Sign in with Apple/Google → gets an identity token (JWT).
  2. iOS sends identity token to POST /api/auth/apple or /api/auth/google.
  3. Server verifies the identity token against Apple/Google JWKS.
  4. Server finds or creates a User row.
  5. Server issues a session JWT signed with SIMMERSMITH_JWT_SECRET.
  6. iOS sends session JWT as Bearer token on all subsequent requests.

Precedence chain for get_current_user:
  1. No auth configured → return dev/local user.
  2. Valid session JWT → return CurrentUser(id=sub).
  3. Legacy api_token match → return dev/local user.
  4. Otherwise → 401.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from secrets import compare_digest

import jwt
from jwt import PyJWKClient
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings, get_settings

logger = logging.getLogger(__name__)

bearer_scheme = HTTPBearer(auto_error=False)

# JWKS clients are cached at module level — PyJWKClient handles key caching
# and refresh internally.
_apple_jwks: PyJWKClient | None = None
_google_jwks: PyJWKClient | None = None

APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"


@dataclass(frozen=True)
class CurrentUser:
    """Minimal authenticated principal. Only holds the stable user id."""
    id: str


class _AuthError(HTTPException):
    def __init__(self, detail: str = "Unauthorized") -> None:
        super().__init__(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=detail,
            headers={"WWW-Authenticate": "Bearer"},
        )


# ── Identity token verification (called from auth routes) ───────────


def _get_apple_jwks() -> PyJWKClient:
    global _apple_jwks
    if _apple_jwks is None:
        _apple_jwks = PyJWKClient(APPLE_JWKS_URL)
    return _apple_jwks


def _get_google_jwks() -> PyJWKClient:
    global _google_jwks
    if _google_jwks is None:
        _google_jwks = PyJWKClient(GOOGLE_JWKS_URL)
    return _google_jwks


def verify_apple_identity_token(token: str, settings: Settings) -> dict:
    """Verify an Apple identity token and return its claims.

    Returns claims dict with at least 'sub' and 'email'.
    Raises _AuthError on any verification failure.
    """
    if not settings.apple_bundle_id:
        raise _AuthError("Apple Sign In not configured")
    try:
        signing_key = _get_apple_jwks().get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.apple_bundle_id,
            issuer="https://appleid.apple.com",
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
            leeway=30,
        )
    except jwt.InvalidTokenError as exc:
        raise _AuthError(f"Invalid Apple token: {exc}") from exc
    return claims


def verify_google_identity_token(token: str, settings: Settings) -> dict:
    """Verify a Google identity token and return its claims."""
    if not settings.google_client_id:
        raise _AuthError("Google Sign In not configured")
    try:
        signing_key = _get_google_jwks().get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.google_client_id,
            issuer=["https://accounts.google.com", "accounts.google.com"],
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
            leeway=30,
        )
    except jwt.InvalidTokenError as exc:
        raise _AuthError(f"Invalid Google token: {exc}") from exc
    return claims


# ── Session JWT (issued by us after identity verification) ──────────


def issue_session_jwt(user_id: str, settings: Settings) -> str:
    """Issue a session JWT signed with our secret."""
    if not settings.jwt_secret:
        raise _AuthError("JWT secret not configured")
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "iat": now,
        "exp": now + timedelta(days=settings.jwt_expiry_days),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def _verify_session_jwt(token: str, settings: Settings) -> str:
    """Verify a session JWT issued by us. Returns user_id or raises."""
    if not settings.jwt_secret:
        raise _AuthError("JWT secret not configured")
    try:
        claims = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            options={"require": ["exp", "iat", "sub"]},
            leeway=30,
        )
    except jwt.InvalidTokenError as exc:
        raise _AuthError(f"Invalid session: {exc}") from exc
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise _AuthError("Session JWT missing subject")
    return sub


# ── FastAPI dependency ──────────────────────────────────────────────


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    settings: Settings = Depends(get_settings),
) -> CurrentUser:
    """Resolve the authenticated user for the current request."""
    jwt_configured = bool(settings.jwt_secret)
    legacy_configured = bool(settings.api_token.strip())

    # (1) Fully open mode — dev and test environments.
    if not jwt_configured and not legacy_configured:
        return CurrentUser(id=settings.local_user_id)

    if credentials is None or credentials.scheme.lower() != "bearer":
        raise _AuthError()

    token = credentials.credentials

    # (2) Try our session JWT first.
    if jwt_configured:
        try:
            user_id = _verify_session_jwt(token, settings)
            return CurrentUser(id=user_id)
        except _AuthError:
            if not legacy_configured:
                raise

    # (3) Legacy bearer token fallback.
    if legacy_configured and compare_digest(token, settings.api_token.strip()):
        return CurrentUser(id=settings.local_user_id)

    raise _AuthError()


# ── Kept for backwards compatibility during migration ───────────────


def require_api_token(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    settings: Settings = Depends(get_settings),
) -> None:
    """Legacy dependency. New code should use get_current_user."""
    expected_token = settings.api_token.strip()
    if not expected_token:
        return
    if (
        credentials is None
        or credentials.scheme.lower() != "bearer"
        or not compare_digest(credentials.credentials, expected_token)
    ):
        raise _AuthError()
