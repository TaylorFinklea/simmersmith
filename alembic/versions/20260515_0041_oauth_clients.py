"""Build 97: OAuth 2.1 + PKCE server for the remote MCP endpoint.

Two new tables backing the authorization-code flow that issues bearer
JWTs for `https://simmersmith.fly.dev/mcp`:

- ``oauth_clients`` — one row per registered OAuth client (typically
  Claude.ai via Dynamic Client Registration).
- ``oauth_authorize_requests`` — short-lived per-attempt state
  carrying the PKCE challenge until token exchange.

Access tokens themselves are stateless JWTs (same secret as session
JWTs, aud="mcp") — no token table.

Revision ID: 20260515_0041
Revises: 20260512_0040
Create Date: 2026-05-15 12:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260515_0041"
down_revision = "20260512_0040"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "oauth_clients",
        sa.Column("client_id", sa.String(length=64), primary_key=True),
        sa.Column("client_secret_hash", sa.String(length=128), nullable=True),
        sa.Column("client_name", sa.String(length=120), nullable=False),
        sa.Column("redirect_uris_json", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "oauth_authorize_requests",
        sa.Column("code", sa.String(length=64), primary_key=True),
        sa.Column("client_id", sa.String(length=64), nullable=False),
        sa.Column("redirect_uri", sa.Text(), nullable=False),
        sa.Column("code_challenge", sa.String(length=128), nullable=False),
        sa.Column("code_challenge_method", sa.String(length=16), nullable=False, server_default="S256"),
        sa.Column("state", sa.Text(), nullable=True),
        sa.Column("scope", sa.Text(), nullable=True),
        sa.Column("user_id", sa.String(length=36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index(
        "ix_oauth_authorize_requests_client_id",
        "oauth_authorize_requests",
        ["client_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_oauth_authorize_requests_client_id", table_name="oauth_authorize_requests")
    op.drop_table("oauth_authorize_requests")
    op.drop_table("oauth_clients")
