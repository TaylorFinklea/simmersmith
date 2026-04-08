from __future__ import annotations

import json
from typing import Any

from fastapi import HTTPException
from fastapi.encoders import jsonable_encoder

from app.config import Settings, get_settings


def _settings() -> Settings:
    return get_settings()


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
