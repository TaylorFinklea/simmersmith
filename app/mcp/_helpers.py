from __future__ import annotations

import contextvars
import json
from typing import Any

from fastapi import HTTPException
from fastapi.encoders import jsonable_encoder

from app.config import Settings, get_settings


def _settings() -> Settings:
    return get_settings()


# Per-request user_id for HTTP MCP calls. The JWT token verifier sets
# this from the validated access token's `sub` claim before the tool
# dispatches. Stdio MCP calls don't authenticate and leave the var
# unset; ``_current_user_id()`` falls through to
# ``settings.local_user_id`` so the existing internal Codex AI routing
# keeps working unchanged.
_current_user_id_var: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "simmersmith_mcp_user_id", default=None
)


def _current_user_id() -> str:
    """Return the user_id to scope an MCP tool call to.

    HTTP path: pulled from the verified OAuth JWT (set by
    ``app.mcp.auth.JWTTokenVerifier.verify_token``). Stdio path: falls
    through to ``settings.local_user_id``.
    """
    value = _current_user_id_var.get()
    if value:
        return value
    return _settings().local_user_id


def _json_ready(value: Any) -> Any:
    return jsonable_encoder(value)


def _raise_tool_error(exc: HTTPException) -> None:
    detail = exc.detail if isinstance(exc.detail, str) else json.dumps(exc.detail)
    raise ValueError(detail) from exc


def _call_route(callback: Any) -> Any:
    """Call a FastAPI route handler and translate HTTPException into ValueError for MCP."""
    try:
        return _json_ready(callback())
    except HTTPException as exc:
        _raise_tool_error(exc)
