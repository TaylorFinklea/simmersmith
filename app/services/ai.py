from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import ProfileSetting


AI_SECRET_KEYS = {"ai_direct_api_key"}
SUPPORTED_DIRECT_PROVIDERS = ("openai", "anthropic")


class AIProvider(Protocol):
    kind: str

    def invocation_mode(self) -> str: ...


@dataclass(frozen=True)
class MCPProvider:
    server_name: str
    kind: str = "mcp"

    def invocation_mode(self) -> str:
        return "mcp"


@dataclass(frozen=True)
class DirectProvider:
    provider_name: str
    key_source: str
    kind: str = "direct"

    def invocation_mode(self) -> str:
        return "direct"


@dataclass(frozen=True)
class AIExecutionTarget:
    provider_kind: str
    mode: str
    source: str
    provider_name: str | None = None
    mcp_server_name: str | None = None

    def as_payload(self) -> dict[str, object]:
        return {
            "provider_kind": self.provider_kind,
            "mode": self.mode,
            "source": self.source,
            "provider_name": self.provider_name,
            "mcp_server_name": self.mcp_server_name,
        }


def profile_settings_map(session: Session) -> dict[str, str]:
    records = session.scalars(select(ProfileSetting).order_by(ProfileSetting.key)).all()
    return {record.key: record.value for record in records}


def visible_profile_settings(settings: dict[str, str]) -> dict[str, str]:
    return {key: value for key, value in settings.items() if key not in AI_SECRET_KEYS}


def secret_profile_flags(settings: dict[str, str]) -> dict[str, bool]:
    return {f"{key}_present": bool(str(settings.get(key, "")).strip()) for key in AI_SECRET_KEYS}


def direct_provider_availability(
    provider_name: str,
    *,
    settings: Settings,
    user_settings: dict[str, str],
) -> tuple[bool, str]:
    profile_provider = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    profile_key = str(user_settings.get("ai_direct_api_key", "")).strip()
    env_key = getattr(settings, f"ai_{provider_name}_api_key", "").strip()
    if profile_provider == provider_name and profile_key:
        return True, "user_override"
    if env_key:
        return True, "server_key"
    return False, "unconfigured"


def resolve_ai_execution_target(
    settings: Settings,
    user_settings: dict[str, str],
) -> AIExecutionTarget | None:
    preferred_mode = str(user_settings.get("ai_provider_mode", "auto")).strip().lower() or "auto"
    preferred_direct = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    direct_options = {
        provider_name: direct_provider_availability(provider_name, settings=settings, user_settings=user_settings)
        for provider_name in SUPPORTED_DIRECT_PROVIDERS
    }
    if preferred_mode in {"mcp", "auto", "hybrid"} and settings.ai_mcp_enabled:
        return AIExecutionTarget(
            provider_kind="mcp",
            mode="mcp",
            source="server",
            mcp_server_name=settings.ai_mcp_server_name,
        )
    if preferred_direct in direct_options and direct_options[preferred_direct][0]:
        return AIExecutionTarget(
            provider_kind="direct",
            mode="direct",
            source=direct_options[preferred_direct][1],
            provider_name=preferred_direct,
        )
    for provider_name, (available, source) in direct_options.items():
        if available:
            return AIExecutionTarget(
                provider_kind="direct",
                mode="direct",
                source=source,
                provider_name=provider_name,
            )
    return None


def ai_capabilities_payload(settings: Settings, user_settings: dict[str, str]) -> dict[str, object]:
    effective_target = resolve_ai_execution_target(settings, user_settings)
    available_providers: list[dict[str, object]] = []
    if settings.ai_mcp_enabled:
        available_providers.append(
            {
                "provider_id": "mcp",
                "label": settings.ai_mcp_server_name,
                "provider_kind": "mcp",
                "available": True,
                "source": "server",
            }
        )
    for provider_name in SUPPORTED_DIRECT_PROVIDERS:
        available, source = direct_provider_availability(provider_name, settings=settings, user_settings=user_settings)
        available_providers.append(
            {
                "provider_id": provider_name,
                "label": provider_name.capitalize(),
                "provider_kind": "direct",
                "available": available,
                "source": source,
            }
        )
    return {
        "supports_user_override": True,
        "preferred_mode": str(user_settings.get("ai_provider_mode", "auto")).strip().lower() or "auto",
        "user_override_provider": str(user_settings.get("ai_direct_provider", "")).strip().lower() or None,
        "user_override_configured": bool(str(user_settings.get("ai_direct_api_key", "")).strip()),
        "default_target": effective_target.as_payload() if effective_target is not None else None,
        "available_providers": available_providers,
    }
