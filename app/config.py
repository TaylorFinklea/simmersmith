from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import computed_field
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
    api_token: str = ""
    ai_mcp_enabled: bool = True
    ai_mcp_server_name: str = "codex"
    ai_mcp_base_url: str = ""
    ai_mcp_auth_token: str = ""
    ai_mcp_tool_name: str = "codex"
    ai_mcp_reply_tool_name: str = "codex-reply"
    ai_openai_api_key: str = ""
    ai_anthropic_api_key: str = ""
    ai_openai_model: str = "gpt-4.1-mini"
    ai_anthropic_model: str = "claude-3-5-sonnet-latest"
    usda_api_key: str = ""
    ai_timeout_seconds: int = 120
    data_dir: Path = Path("/Users/tfinklea/codex/meals/data")
    db_path: Path = Path("/Users/tfinklea/codex/meals/data/meals.db")
    frontend_dist_dir: Path = Path(__file__).resolve().parents[1] / "frontend" / "dist"

    @computed_field  # type: ignore[misc] -- Pydantic computed_field + property combo confuses type checker
    @property
    def database_url(self) -> str:
        return f"sqlite:///{self.db_path}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    settings = Settings()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    settings.db_path.parent.mkdir(parents=True, exist_ok=True)
    return settings
