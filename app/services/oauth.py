"""OAuth 2.1 + PKCE business logic for the remote MCP endpoint.

Implements the authorization-code grant with PKCE (RFC 7636) and
Dynamic Client Registration (RFC 7591). Backed by ``oauth_clients``
and ``oauth_authorize_requests`` tables. Issues bearer JWTs (audience
"mcp") that the MCP endpoint validates via ``app.mcp.auth``.

V1 user-auth in the authorize page is bearer-token paste (the existing
SIMMERSMITH_API_TOKEN identifies the local admin user). Real Apple /
Google web sign-in is a follow-up milestone — the OAuth surface here
doesn't change when that lands; only the authorize page's HTML does.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable

import jwt
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import OAuthAuthorizeRequest, OAuthClient, utcnow

# OAuth access-token audience claim. The MCP verifier rejects tokens
# whose ``aud`` isn't this string so session JWTs can't be replayed
# against /mcp.
MCP_TOKEN_AUDIENCE = "mcp"

# Pending-authorize-request TTL. The user has this long after Claude.ai
# hits /authorize to complete the approval before the code expires.
AUTHORIZE_REQUEST_TTL_SECONDS = 300

# Access-token TTL once issued.
ACCESS_TOKEN_TTL_DAYS = 30


class OAuthError(Exception):
    """Raised when an OAuth request is malformed or fails policy.

    Carries a ``code`` matching the OAuth 2.1 error vocabulary
    (``invalid_request``, ``invalid_client``, ``invalid_grant``,
    ``unauthorized_client``, ``unsupported_grant_type``,
    ``invalid_scope``). Callers translate this into the appropriate
    HTTP response.
    """

    def __init__(self, code: str, description: str) -> None:
        super().__init__(description)
        self.code = code
        self.description = description


def _new_token(byte_len: int = 32) -> str:
    """Return a URL-safe random token of the requested entropy."""
    return secrets.token_urlsafe(byte_len)


def _as_utc(value: datetime) -> datetime:
    """Normalize a possibly-naive datetime (e.g. from SQLite) to UTC.

    Without this, comparing ``row.expires_at <= datetime.now(timezone.utc)``
    raises ``TypeError`` whenever the row was read from SQLite, which
    stores datetimes without tzinfo.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


def _b64url_sha256(value: str) -> str:
    digest = hashlib.sha256(value.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


# ── Dynamic Client Registration (RFC 7591) ──────────────────────────


@dataclass(frozen=True)
class RegisteredClient:
    client_id: str
    client_name: str
    redirect_uris: list[str]


def register_client(
    session: Session,
    *,
    client_name: str,
    redirect_uris: list[str],
) -> RegisteredClient:
    """Create a new OAuth client.

    Claude.ai is treated as a public client — no ``client_secret`` is
    issued; PKCE is the proof-of-possession. ``redirect_uris`` must be
    non-empty.
    """
    cleaned_uris = [uri.strip() for uri in redirect_uris if uri and uri.strip()]
    if not cleaned_uris:
        raise OAuthError("invalid_redirect_uri", "At least one redirect_uri is required.")

    name = (client_name or "").strip() or "Unnamed Client"
    client = OAuthClient(
        client_id=_new_token(16),
        client_secret_hash=None,
        client_name=name,
        redirect_uris_json=json.dumps(cleaned_uris),
    )
    session.add(client)
    session.flush()
    return RegisteredClient(
        client_id=client.client_id,
        client_name=client.client_name,
        redirect_uris=cleaned_uris,
    )


def _client_redirect_uris(client: OAuthClient) -> list[str]:
    try:
        decoded = json.loads(client.redirect_uris_json or "[]")
    except json.JSONDecodeError:
        return []
    return [str(uri) for uri in decoded if isinstance(uri, str)]


def get_client(session: Session, client_id: str) -> OAuthClient | None:
    if not client_id:
        return None
    return session.scalar(select(OAuthClient).where(OAuthClient.client_id == client_id))


# ── Authorization endpoint ──────────────────────────────────────────


@dataclass(frozen=True)
class AuthorizeRequestInputs:
    client_id: str
    redirect_uri: str
    code_challenge: str
    code_challenge_method: str
    state: str | None
    scope: str | None


def validate_authorize_request(
    session: Session,
    inputs: AuthorizeRequestInputs,
) -> OAuthClient:
    """Validate an inbound /oauth/authorize query.

    Returns the matched client if all parameters are well-formed and
    the redirect_uri is registered. Raises ``OAuthError`` otherwise.
    """
    if not inputs.client_id:
        raise OAuthError("invalid_request", "Missing client_id.")
    client = get_client(session, inputs.client_id)
    if client is None:
        raise OAuthError("invalid_client", "Unknown client_id.")

    if not inputs.redirect_uri:
        raise OAuthError("invalid_request", "Missing redirect_uri.")
    if inputs.redirect_uri not in _client_redirect_uris(client):
        raise OAuthError("invalid_request", "redirect_uri is not registered for this client.")

    if not inputs.code_challenge:
        raise OAuthError("invalid_request", "PKCE is required: missing code_challenge.")
    if inputs.code_challenge_method != "S256":
        raise OAuthError(
            "invalid_request",
            "Only PKCE code_challenge_method=S256 is supported.",
        )
    return client


def create_pending_authorize_request(
    session: Session,
    *,
    client: OAuthClient,
    inputs: AuthorizeRequestInputs,
) -> OAuthAuthorizeRequest:
    """Insert the pending-request row that holds PKCE + state across the
    user-approval step. The returned row's ``code`` is what we hand to
    the client's redirect_uri once the user approves."""
    now = datetime.now(timezone.utc)
    row = OAuthAuthorizeRequest(
        code=_new_token(32),
        client_id=client.client_id,
        redirect_uri=inputs.redirect_uri,
        code_challenge=inputs.code_challenge,
        code_challenge_method=inputs.code_challenge_method,
        state=inputs.state,
        scope=inputs.scope,
        user_id=None,
        expires_at=now + timedelta(seconds=AUTHORIZE_REQUEST_TTL_SECONDS),
    )
    session.add(row)
    session.flush()
    return row


def approve_authorize_request(
    session: Session,
    *,
    code: str,
    user_id: str,
) -> OAuthAuthorizeRequest:
    """Mark a pending authorization request as approved by ``user_id``.

    Called from the authorize page once the operator confirms the
    sign-in. After this, ``/oauth/token`` can exchange the code for an
    access token (still subject to PKCE + expiry checks).
    """
    row = session.scalar(
        select(OAuthAuthorizeRequest).where(OAuthAuthorizeRequest.code == code)
    )
    if row is None:
        raise OAuthError("invalid_grant", "Unknown authorization request.")
    if _as_utc(row.expires_at) <= datetime.now(timezone.utc):
        raise OAuthError("invalid_grant", "Authorization request expired.")
    if row.user_id is not None:
        raise OAuthError("invalid_grant", "Authorization request already approved.")
    row.user_id = user_id
    row.approved_at = utcnow()
    session.flush()
    return row


# ── Token endpoint ──────────────────────────────────────────────────


def _verify_pkce(code_challenge: str, code_challenge_method: str, code_verifier: str) -> bool:
    if code_challenge_method != "S256":
        return False
    if not code_verifier:
        return False
    expected = _b64url_sha256(code_verifier)
    return hmac.compare_digest(expected, code_challenge)


@dataclass(frozen=True)
class TokenExchangeInputs:
    grant_type: str
    code: str
    client_id: str
    redirect_uri: str
    code_verifier: str


@dataclass(frozen=True)
class TokenGrant:
    access_token: str
    token_type: str  # always "Bearer"
    expires_in: int  # seconds
    scope: str | None


def exchange_code_for_token(
    session: Session,
    settings: Settings,
    inputs: TokenExchangeInputs,
) -> TokenGrant:
    """Exchange an approved authorization code for a bearer access token.

    Validates PKCE, single-use, client match, redirect_uri match.
    Deletes the row so the code cannot be replayed.
    """
    if inputs.grant_type != "authorization_code":
        raise OAuthError("unsupported_grant_type", "Only authorization_code is supported.")
    if not inputs.code:
        raise OAuthError("invalid_request", "Missing code.")

    row = session.scalar(
        select(OAuthAuthorizeRequest).where(OAuthAuthorizeRequest.code == inputs.code)
    )
    if row is None:
        raise OAuthError("invalid_grant", "Unknown or already-used code.")
    if row.user_id is None:
        raise OAuthError("invalid_grant", "Authorization request was not approved.")
    if _as_utc(row.expires_at) <= datetime.now(timezone.utc):
        # Clean up the expired row as we go.
        session.delete(row)
        session.flush()
        raise OAuthError("invalid_grant", "Authorization code expired.")
    if row.client_id != inputs.client_id:
        raise OAuthError("invalid_client", "Code was issued to a different client.")
    if row.redirect_uri != inputs.redirect_uri:
        raise OAuthError("invalid_grant", "redirect_uri does not match the authorize request.")
    if not _verify_pkce(row.code_challenge, row.code_challenge_method, inputs.code_verifier):
        raise OAuthError("invalid_grant", "PKCE verifier did not match challenge.")

    token = issue_mcp_access_token(
        user_id=row.user_id,
        client_id=row.client_id,
        settings=settings,
        scope=row.scope,
    )

    # Bump the client's last_used_at for visibility.
    client = get_client(session, row.client_id)
    if client is not None:
        client.last_used_at = utcnow()

    # Codes are single-use.
    session.delete(row)
    session.flush()

    return TokenGrant(
        access_token=token,
        token_type="Bearer",
        expires_in=ACCESS_TOKEN_TTL_DAYS * 24 * 3600,
        scope=row.scope,
    )


# ── Access-token issuance + verification ────────────────────────────


def issue_mcp_access_token(
    *,
    user_id: str,
    client_id: str,
    settings: Settings,
    scope: str | None = None,
) -> str:
    """Issue a JWT access token for the MCP endpoint.

    Signed with the same secret as session JWTs but carries ``aud="mcp"``
    so the MCP verifier rejects accidentally-replayed session tokens.
    """
    if not settings.jwt_secret:
        raise OAuthError("server_error", "JWT secret not configured.")
    now = datetime.now(timezone.utc)
    payload: dict[str, object] = {
        "sub": user_id,
        "aud": MCP_TOKEN_AUDIENCE,
        "iat": now,
        "exp": now + timedelta(days=ACCESS_TOKEN_TTL_DAYS),
        "client_id": client_id,
    }
    if scope:
        payload["scope"] = scope
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


@dataclass(frozen=True)
class VerifiedAccessToken:
    user_id: str
    client_id: str
    scope: str | None


def verify_mcp_access_token(token: str, settings: Settings) -> VerifiedAccessToken:
    """Validate a JWT issued by ``issue_mcp_access_token``.

    Raises ``OAuthError("invalid_token", ...)`` on any signature, aud,
    or expiry failure so the MCP layer can return a clean 401.
    """
    if not settings.jwt_secret:
        raise OAuthError("server_error", "JWT secret not configured.")
    if not token:
        raise OAuthError("invalid_token", "Missing token.")
    try:
        claims = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            audience=MCP_TOKEN_AUDIENCE,
            options={"require": ["exp", "iat", "sub", "aud"]},
            leeway=30,
        )
    except jwt.InvalidTokenError as exc:
        raise OAuthError("invalid_token", str(exc)) from exc
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise OAuthError("invalid_token", "Token missing subject.")
    client_id = claims.get("client_id")
    if not isinstance(client_id, str) or not client_id:
        raise OAuthError("invalid_token", "Token missing client_id claim.")
    scope = claims.get("scope")
    return VerifiedAccessToken(
        user_id=sub,
        client_id=client_id,
        scope=str(scope) if isinstance(scope, str) else None,
    )


# ── Discovery metadata ──────────────────────────────────────────────


def authorization_server_metadata(base_url: str, *, scopes: Iterable[str] = ()) -> dict[str, object]:
    """Return the OAuth 2.1 authorization-server metadata document
    served at /.well-known/oauth-authorization-server.

    ``base_url`` should be the externally-visible host root, e.g.
    ``https://simmersmith.fly.dev``.
    """
    base = base_url.rstrip("/")
    return {
        "issuer": base,
        "authorization_endpoint": f"{base}/oauth/authorize",
        "token_endpoint": f"{base}/oauth/token",
        "registration_endpoint": f"{base}/oauth/register",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code"],
        "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["none"],  # public client + PKCE
        "scopes_supported": list(scopes) or ["mcp"],
    }
