"""OAuth 2.1 server tables for the remote MCP endpoint.

The MCP server at `/mcp` requires bearer auth. The access tokens are
stateless JWTs (signed with the existing session JWT secret, aud="mcp"),
so there's no token table. The two tables here back the
**authorization-code + PKCE** flow that issues those tokens.

- `OAuthClient` — one row per OAuth client (typically a single
  "Claude.ai" row created via Dynamic Client Registration).
- `OAuthAuthorizeRequest` — short-lived (60s TTL) per-attempt row
  recording the PKCE challenge + redirect target until the user
  approves. Deleted on token exchange to prevent replay.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models._base import utcnow


class OAuthClient(Base):
    """A registered OAuth client (e.g. Claude.ai).

    Public clients (Claude.ai is one) carry no `client_secret_hash` and
    are required to use PKCE. `redirect_uris_json` is a JSON-encoded
    array; the authorize endpoint validates the incoming
    `redirect_uri` is a member.
    """
    __tablename__ = "oauth_clients"

    client_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    client_secret_hash: Mapped[str | None] = mapped_column(String(128), nullable=True)
    client_name: Mapped[str] = mapped_column(String(120), nullable=False)
    redirect_uris_json: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class OAuthAuthorizeRequest(Base):
    """Pending authorization-code state for an in-flight OAuth attempt.

    Row created when `/oauth/authorize` is hit; `user_id` is filled in
    when the user approves. `/oauth/token` deletes the row after a
    successful PKCE-verified exchange. Rows older than ~5 minutes are
    safe to garbage-collect (the code TTL is 60s once issued, but the
    pre-approval state can sit longer).
    """
    __tablename__ = "oauth_authorize_requests"

    code: Mapped[str] = mapped_column(String(64), primary_key=True)
    client_id: Mapped[str] = mapped_column(String(64), index=True, nullable=False)
    redirect_uri: Mapped[str] = mapped_column(Text, nullable=False)
    code_challenge: Mapped[str] = mapped_column(String(128), nullable=False)
    code_challenge_method: Mapped[str] = mapped_column(String(16), nullable=False, default="S256")
    state: Mapped[str | None] = mapped_column(Text, nullable=True)
    scope: Mapped[str | None] = mapped_column(Text, nullable=True)
    user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
