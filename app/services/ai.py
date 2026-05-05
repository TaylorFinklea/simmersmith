from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import ProfileSetting
from app.services.mcp_client import mcp_is_configured, probe_codex_mcp


LEGACY_DIRECT_API_KEY = "ai_direct_api_key"
PROVIDER_PROFILE_API_KEY_KEYS = {
    "openai": "ai_openai_api_key",
    "anthropic": "ai_anthropic_api_key",
}
# apns_device_token is stored in push_devices, not profile_settings, but defense-
# in-depth: if someone ever writes a key here it shouldn't leak through GET /api/profile.
AI_SECRET_KEYS = {LEGACY_DIRECT_API_KEY, "apns_device_token", *PROVIDER_PROFILE_API_KEY_KEYS.values()}
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


def profile_settings_map(session: Session, user_id: str) -> dict[str, str]:
    records = session.scalars(
        select(ProfileSetting)
        .where(ProfileSetting.user_id == user_id)
        .order_by(ProfileSetting.key)
    ).all()
    return {record.key: record.value for record in records}


def visible_profile_settings(settings: dict[str, str]) -> dict[str, str]:
    return {key: value for key, value in settings.items() if key not in AI_SECRET_KEYS}


def unit_system(user_settings: dict[str, str]) -> str:
    """Normalize the user's `unit_system` profile setting.

    Returns one of `"us"` or `"metric"`. Empty / unrecognized values
    fall back to `"us"` so legacy users (no setting) get the original
    behavior.
    """
    raw = str(user_settings.get("unit_system", "")).strip().lower()
    return "metric" if raw == "metric" else "us"


def unit_system_directive(user_settings: dict[str, str]) -> str:
    """Prompt fragment that locks AI-produced recipes to the user's
    preferred unit system. Inject near the top of the system prompt
    so the rule outranks any unit hints the LLM picked up from the
    request text or training data.
    """
    if unit_system(user_settings) == "metric":
        return (
            "UNIT SYSTEM — METRIC ONLY. All ingredient quantities must use "
            "metric units (g, kg, ml, l). All temperatures must be in °C. "
            "Convert any imperial values from your sources before returning. "
            "Do not mix systems."
        )
    return (
        "UNIT SYSTEM — US CUSTOMARY ONLY. All ingredient quantities must use "
        "US customary units (cups, tbsp, tsp, oz, lb, fl oz). All temperatures "
        "must be in °F. Convert any metric values from your sources before "
        "returning. Do not mix systems."
    )


def secret_profile_flags(settings: dict[str, str]) -> dict[str, bool]:
    return {f"{key}_present": bool(str(settings.get(key, "")).strip()) for key in AI_SECRET_KEYS}


def _profile_direct_api_key(provider_name: str, user_settings: dict[str, str]) -> tuple[str, str]:
    provider_key = str(user_settings.get(PROVIDER_PROFILE_API_KEY_KEYS[provider_name], "")).strip()
    if provider_key:
        return provider_key, "user_override"
    profile_provider = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    legacy_key = str(user_settings.get(LEGACY_DIRECT_API_KEY, "")).strip()
    if profile_provider == provider_name and legacy_key:
        return legacy_key, "user_override"
    return "", "unconfigured"


def direct_provider_availability(
    provider_name: str,
    *,
    settings: Settings,
    user_settings: dict[str, str],
) -> tuple[bool, str]:
    profile_key, profile_source = _profile_direct_api_key(provider_name, user_settings)
    env_key = getattr(settings, f"ai_{provider_name}_api_key", "").strip()
    if profile_key:
        return True, profile_source
    if env_key:
        return True, "server_key"
    return False, "unconfigured"


def resolve_direct_api_key(
    provider_name: str,
    *,
    settings: Settings,
    user_settings: dict[str, str],
) -> str:
    override_key, _ = _profile_direct_api_key(provider_name, user_settings)
    if override_key:
        return override_key
    if provider_name == "openai":
        return settings.ai_openai_api_key.strip()
    if provider_name == "anthropic":
        return settings.ai_anthropic_api_key.strip()
    return ""


def resolve_direct_model(
    provider_name: str,
    *,
    settings: Settings,
    user_settings: dict[str, str],
) -> str:
    override_key = f"ai_{provider_name}_model"
    override_model = str(user_settings.get(override_key, "")).strip()
    if override_model:
        return override_model
    if provider_name == "openai":
        return settings.ai_openai_model
    if provider_name == "anthropic":
        return settings.ai_anthropic_model
    return ""


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
    mcp_ready = mcp_is_configured(settings)
    if preferred_mode == "mcp" and mcp_ready:
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
    if preferred_mode in {"mcp", "auto", "hybrid", "direct"} and mcp_ready:
        return AIExecutionTarget(
            provider_kind="mcp",
            mode="mcp",
            source="server",
            mcp_server_name=settings.ai_mcp_server_name,
        )
    return None


async def ai_capabilities_payload(settings: Settings, user_settings: dict[str, str]) -> dict[str, object]:
    preferred_mode = str(user_settings.get("ai_provider_mode", "auto")).strip().lower() or "auto"
    preferred_direct = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    direct_options = {
        provider_name: direct_provider_availability(provider_name, settings=settings, user_settings=user_settings)
        for provider_name in SUPPORTED_DIRECT_PROVIDERS
    }
    mcp_available, mcp_source = await probe_codex_mcp(settings)
    available_providers: list[dict[str, object]] = []
    available_providers.append(
        {
            "provider_id": "mcp",
            "label": settings.ai_mcp_server_name,
            "provider_kind": "mcp",
            "available": mcp_available,
            "source": mcp_source,
        }
    )
    for provider_name in SUPPORTED_DIRECT_PROVIDERS:
        available, source = direct_options[provider_name]
        available_providers.append(
            {
                "provider_id": provider_name,
                "label": provider_name.capitalize(),
                "provider_kind": "direct",
                "available": available,
                "source": source,
            }
        )
    effective_target: AIExecutionTarget | None = None
    if preferred_mode == "mcp" and mcp_available:
        effective_target = AIExecutionTarget(
            provider_kind="mcp",
            mode="mcp",
            source=mcp_source,
            mcp_server_name=settings.ai_mcp_server_name,
        )
    elif preferred_direct in direct_options and direct_options[preferred_direct][0]:
        effective_target = AIExecutionTarget(
            provider_kind="direct",
            mode="direct",
            source=direct_options[preferred_direct][1],
            provider_name=preferred_direct,
        )
    else:
        for provider_name, (available, source) in direct_options.items():
            if available:
                effective_target = AIExecutionTarget(
                    provider_kind="direct",
                    mode="direct",
                    source=source,
                    provider_name=provider_name,
                )
                break
        if effective_target is None and mcp_available:
            effective_target = AIExecutionTarget(
                provider_kind="mcp",
                mode="mcp",
                source=mcp_source,
                mcp_server_name=settings.ai_mcp_server_name,
            )

    return {
        "supports_user_override": True,
        "preferred_mode": preferred_mode,
        "user_override_provider": preferred_direct or None,
        "user_override_configured": any(
            bool(_profile_direct_api_key(provider_name, user_settings)[0])
            for provider_name in SUPPORTED_DIRECT_PROVIDERS
        ),
        "default_target": effective_target.as_payload() if effective_target is not None else None,
        "available_providers": available_providers,
    }
