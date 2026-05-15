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


@asynccontextmanager
async def lifespan(_: FastMCP):
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
    from .auth import JWTTokenVerifier

    settings = get_settings()
    issuer = getattr(settings, "oauth_issuer", "") or "https://simmersmith.fly.dev"
    auth = AuthSettings(
        issuer_url=issuer,
        resource_server_url=f"{issuer}/mcp",
        required_scopes=[],
    )
    http_mcp = FastMCP(
        name=mcp.name,
        instructions=mcp.instructions,
        tools=mcp._tool_manager.list_tools(),
        streamable_http_path="/",
        lifespan=lifespan,
        auth=auth,
        token_verifier=JWTTokenVerifier(),
    )
    return http_mcp.streamable_http_app()


__all__ = ["mcp", "main", "lifespan", "parse_args", "StaticBearerTokenVerifier", "build_http_app"]
