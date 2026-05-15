"""JWT-backed ``TokenVerifier`` for the remote MCP endpoint.

Validates bearer JWTs minted by ``/oauth/token``. On success, sets the
per-request ``_current_user_id_var`` ContextVar so domain modules
under ``app/mcp/`` scope their queries to the right user / household.
"""
from __future__ import annotations

import time

from mcp.server.auth.provider import AccessToken, TokenVerifier

from app.config import get_settings
from app.services.oauth import OAuthError, verify_mcp_access_token

from ._helpers import _current_user_id_var


class JWTTokenVerifier(TokenVerifier):
    """Verifies an OAuth-issued JWT and binds the user_id for the call."""

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            verified = verify_mcp_access_token(token, get_settings())
        except OAuthError:
            return None
        _current_user_id_var.set(verified.user_id)
        scopes = [verified.scope] if verified.scope else []
        return AccessToken(
            token=token,
            client_id=verified.client_id,
            scopes=scopes,
            expires_at=int(time.time()) + 30 * 86400,
        )
