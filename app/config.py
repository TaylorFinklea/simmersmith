from __future__ import annotations

import os
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SIMMERSMITH_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    host: str = "0.0.0.0"
    port: int = 8080
    base_url: str = "http://localhost:8080"
    # Reads SIMMERSMITH_DATABASE_URL first; falls back to DATABASE_URL (Fly.io convention).
    # Fly/Heroku use "postgres://" but SQLAlchemy requires "postgresql://".
    database_url: str = os.environ.get(
        "DATABASE_URL", "postgresql://simmersmith:simmersmith@localhost:5432/simmersmith"
    ).replace("postgres://", "postgresql://", 1)

    # Auth — session JWT
    jwt_secret: str = ""
    jwt_algorithm: str = "HS256"
    jwt_expiry_days: int = 30

    # Auth — Apple Sign In (iOS sends identity token, we verify)
    apple_bundle_id: str = ""

    # Auth — Google Sign In (iOS sends identity token, we verify)
    google_client_id: str = ""

    # Legacy bearer token — maps to a dev/local user for MCP and self-hosted
    api_token: str = ""
    local_user_id: str = "00000000-0000-0000-0000-000000000001"

    # AI provider configuration
    ai_mcp_enabled: bool = True
    ai_mcp_server_name: str = "codex"
    ai_mcp_base_url: str = ""
    ai_mcp_auth_token: str = ""
    ai_mcp_tool_name: str = "codex"
    ai_mcp_reply_tool_name: str = "codex-reply"
    ai_openai_api_key: str = ""
    ai_anthropic_api_key: str = ""
    ai_openai_model: str = "gpt-5.4-mini"
    ai_anthropic_model: str = "claude-3-5-sonnet-latest"
    usda_api_key: str = ""
    ai_timeout_seconds: int = 120

    # Kroger API (grocery pricing)
    kroger_client_id: str = ""
    kroger_client_secret: str = ""


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
