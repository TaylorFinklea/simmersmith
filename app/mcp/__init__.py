from __future__ import annotations

import argparse
import time
from contextlib import asynccontextmanager
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings

from app.config import get_settings
from app.db import session_scope
from app.services.bootstrap import run_migrations, seed_defaults

from ._helpers import _json_ready


class StaticBearerTokenVerifier(TokenVerifier):
    def __init__(
        self,
        token: str,
        *,
        client_id: str = "simmersmith-mcp-client",
        scopes: list[str] | None = None,
    ):
        self._token = token.strip()
        self._client_id = client_id
        self._scopes = scopes or []

    async def verify_token(self, token: str) -> AccessToken | None:
        if not self._token or token.strip() != self._token:
            return None
        return AccessToken(
            token=token.strip(),
            client_id=self._client_id,
            scopes=self._scopes,
            expires_at=int(time.time()) + 86400,
        )


# Process-level guard so migrations + seed run at most once. The mounted
# HTTP path calls mark_startup_complete() from app.main's lifespan (which
# already migrated/seeded), so entering this lifespan there is a no-op
# instead of redoing the work (M19). The stdio path (main()) runs it once.
_startup_ran = False


def mark_startup_complete() -> None:
    """Record that migrations + seed have already run this process."""
    global _startup_ran
    _startup_ran = True


@asynccontextmanager
async def lifespan(_: FastMCP):
    global _startup_ran
    if not _startup_ran:
        _startup_ran = True
        run_migrations()
        with session_scope() as session:
            seed_defaults(session)
    yield


mcp = FastMCP(
    name="SimmerSmith",
    instructions=(
        "Use these tools to read and update the SimmerSmith meal-planning app state. "
        "Prefer draft-first flows for recipe AI actions and assistant interactions."
    ),
    lifespan=lifespan,
)


@mcp.tool(description="Get SimmerSmith health and AI capability status.")
async def health() -> dict[str, Any]:
    return _json_ready({"status": "ok"})


# Import tool modules so @mcp.tool decorators register all tools.
from app.mcp import recipes as _recipes  # noqa: E402, F401
from app.mcp import ingredients as _ingredients  # noqa: E402, F401
from app.mcp import weeks as _weeks  # noqa: E402, F401
from app.mcp import profile as _profile  # noqa: E402, F401
from app.mcp import assistant as _assistant  # noqa: E402, F401


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the SimmerSmith MCP server.")
    parser.add_argument("--transport", choices=["stdio", "streamable-http"], default="stdio")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--path", default="/mcp")
    parser.add_argument(
        "--bearer-token",
        default="",
        help="Optional static bearer token for streamable-http mode. Ignored for stdio mode.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.transport == "streamable-http":
        auth = None
        token_verifier = None
        if args.bearer_token.strip():
            auth = AuthSettings(
                issuer_url=f"http://{args.host}:{args.port}",
                resource_server_url=f"http://{args.host}:{args.port}{args.path}",
                required_scopes=[],
            )
            token_verifier = StaticBearerTokenVerifier(args.bearer_token.strip())
        http_mcp = FastMCP(
            name=mcp.name,
            instructions=mcp.instructions,
            tools=mcp._tool_manager.list_tools(),
            host=args.host,
            port=args.port,
            streamable_http_path=args.path,
            lifespan=lifespan,
            auth=auth,
            token_verifier=token_verifier,
        )
        http_mcp.run(transport="streamable-http")
        return
    mcp.run(transport="stdio")


def build_http_app():
    """Return an ASGI app that serves the SimmerSmith MCP over Streamable
    HTTP with OAuth-JWT bearer auth. Mounted on the FastAPI app at
    ``/mcp`` so SimmerSmith's existing process can host both the REST
    surface and the MCP surface from one origin.

    The JWT verifier sets the ``_current_user_id_var`` ContextVar so
    domain modules scope their queries to the OAuth-authenticated
    user. The stdio path (``main()``) is unaffected and keeps using
    the implicit ``local_user_id`` fall-through in ``_helpers``.
    """
    # Lazy import — the FastAPI app loads this module at startup and
    # ``auth.py`` pulls in ``app.services.oauth`` which depends on
    # configured settings.
    from mcp.server.transport_security import TransportSecuritySettings

    from .auth import JWTTokenVerifier

    settings = get_settings()
    issuer = getattr(settings, "oauth_issuer", "") or "https://simmersmith.fly.dev"
    auth = AuthSettings(
        issuer_url=issuer,
        resource_server_url=f"{issuer}/mcp",
        required_scopes=[],
    )
    # DNS-rebinding protection (Host/Origin allow-listing) exists to stop a
    # malicious web page from reaching a *local* MCP server via a victim's
    # browser. This is a public server where every /mcp request already
    # requires a valid OAuth bearer token, so the protection is inapplicable
    # and only causes false rejections: the SDK default 421s the public Host,
    # and it 403s the `Origin: https://claude.ai` that Claude's connector
    # sends. Disable it — the OAuth bearer requirement is the access control.
    transport_security = TransportSecuritySettings(enable_dns_rebinding_protection=False)
    http_mcp = FastMCP(
        name=mcp.name,
        instructions=mcp.instructions,
        tools=mcp._tool_manager.list_tools(),
        # Transport at "/mcp"; the app is mounted at root in app/main.py, so
        # `POST /mcp` resolves with no trailing-slash redirect. A 307 (from
        # mounting at "/mcp" with the transport at "/") is not followed by
        # the MCP client and the connector fails.
        streamable_http_path="/mcp",
        # Stateless: create a fresh transport + server task per request. In
        # the default STATEFUL mode the per-session server task's context is
        # frozen at session-creation, so `verify_token` setting the
        # per-request user (`_current_user_id_var`) never reaches tool
        # dispatch — every tool ran as whoever created the session (or fell
        # through to local_user_id), a cross-tenant identity bug. Stateless
        # starts the server task from within each request's task, so anyio
        # copies that request's context (the authenticated user) in, and the
        # existing ContextVar scoping in app/mcp/_helpers is correct and
        # leak-free per request.
        stateless_http=True,
        lifespan=lifespan,
        auth=auth,
        token_verifier=JWTTokenVerifier(),
        transport_security=transport_security,
    )
    return http_mcp.streamable_http_app()


__all__ = [
    "mcp", "main", "lifespan", "parse_args", "StaticBearerTokenVerifier",
    "build_http_app", "mark_startup_complete",
]
