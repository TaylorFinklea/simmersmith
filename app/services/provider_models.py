from __future__ import annotations

from typing import Any

import httpx

from app.config import Settings
from app.services.ai import SUPPORTED_DIRECT_PROVIDERS, direct_provider_availability, resolve_direct_api_key, resolve_direct_model


OPENAI_MODEL_PREFERENCES = (
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5",
    "gpt-5-mini",
    "gpt-4.1",
    "gpt-4.1-mini",
    "o3",
    "o4-mini",
)
OPENAI_MODEL_PREFIXES = tuple({model_id.split("-")[0] for model_id in OPENAI_MODEL_PREFERENCES})


def _is_openai_chat_model(model_id: str) -> bool:
    return model_id.startswith(("gpt-", "o",))


def _is_supported_openai_model(model_id: str) -> bool:
    return any(model_id == candidate or model_id.startswith(f"{candidate}-") for candidate in OPENAI_MODEL_PREFERENCES)


def _openai_sort_key(model_id: str) -> tuple[int, str]:
    for index, candidate in enumerate(OPENAI_MODEL_PREFERENCES):
        if model_id == candidate or model_id.startswith(f"{candidate}-"):
            return index, model_id
    return len(OPENAI_MODEL_PREFERENCES), model_id


def _append_saved_model(
    models: list[dict[str, str]],
    *,
    selected_model_id: str,
    provider_name: str,
) -> list[dict[str, str]]:
    if not selected_model_id:
        return models
    if any(item["model_id"] == selected_model_id for item in models):
        return models
    display_name = f"{selected_model_id} (saved)"
    return [{"provider_id": provider_name, "model_id": selected_model_id, "display_name": display_name}] + models


def list_provider_models(
    provider_name: str,
    *,
    settings: Settings,
    user_settings: dict[str, str],
) -> dict[str, object]:
    normalized_provider = provider_name.strip().lower()
    if normalized_provider not in SUPPORTED_DIRECT_PROVIDERS:
        raise ValueError("Unsupported direct provider.")

    available, source = direct_provider_availability(normalized_provider, settings=settings, user_settings=user_settings)
    if not available:
        raise RuntimeError(f"{normalized_provider.capitalize()} is not configured on the server.")

    api_key = resolve_direct_api_key(normalized_provider, settings=settings, user_settings=user_settings)
    if not api_key:
        raise RuntimeError(f"{normalized_provider.capitalize()} is not configured on the server.")

    selected_model_id = resolve_direct_model(normalized_provider, settings=settings, user_settings=user_settings)

    if normalized_provider == "openai":
        models = _list_openai_models(api_key, timeout=settings.ai_timeout_seconds)
    else:
        models = _list_anthropic_models(api_key, timeout=settings.ai_timeout_seconds)

    models = _append_saved_model(models, selected_model_id=selected_model_id, provider_name=normalized_provider)
    return {
        "provider_id": normalized_provider,
        "selected_model_id": selected_model_id or None,
        "models": models,
        "source": source,
    }


def _list_openai_models(api_key: str, *, timeout: int) -> list[dict[str, str]]:
    headers = {"Authorization": f"Bearer {api_key}"}
    with httpx.Client(timeout=timeout) as client:
        response = client.get("https://api.openai.com/v1/models", headers=headers)
    response.raise_for_status()
    payload = response.json()
    data = payload.get("data", [])
    models = []
    for item in data:
        model_id = str(item.get("id", "")).strip()
        if not model_id or not _is_openai_chat_model(model_id) or not _is_supported_openai_model(model_id):
            continue
        models.append(
            {
                "provider_id": "openai",
                "model_id": model_id,
                "display_name": model_id,
            }
        )
    models.sort(key=lambda item: _openai_sort_key(item["model_id"]))
    return models


def _list_anthropic_models(api_key: str, *, timeout: int) -> list[dict[str, str]]:
    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    models: list[dict[str, str]] = []
    after: str | None = None

    with httpx.Client(timeout=timeout) as client:
        while True:
            params: dict[str, Any] = {"limit": 100}
            if after:
                params["after_id"] = after
            response = client.get("https://api.anthropic.com/v1/models", headers=headers, params=params)
            response.raise_for_status()
            payload = response.json()
            data = payload.get("data", [])
            for item in data:
                model_id = str(item.get("id", "")).strip()
                if not model_id or not model_id.startswith("claude-"):
                    continue
                display_name = str(item.get("display_name") or model_id).strip() or model_id
                models.append(
                    {
                        "provider_id": "anthropic",
                        "model_id": model_id,
                        "display_name": display_name,
                    }
                )
            has_more = bool(payload.get("has_more"))
            last_id = str(payload.get("last_id") or "").strip()
            if not has_more or not last_id:
                break
            after = last_id

    models.sort(key=lambda item: item["display_name"].lower())
    return models
