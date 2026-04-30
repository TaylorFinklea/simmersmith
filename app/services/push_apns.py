"""APNs sender service (M18 push notifications).

Wraps aioapns for token-based APNs auth. Lazily constructs one APNs
client per environment ("sandbox" or "production") so we never mix
sandbox tokens with the production gateway.
"""
from __future__ import annotations

import logging
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models._base import utcnow
from app.models.push import PushDevice

logger = logging.getLogger(__name__)

# Cache per (team_id, key_id, environment) so a restart rebuilds cleanly.
_apns_clients: dict[tuple[str, str, str], Any] = {}


def is_apns_configured(settings: Settings) -> bool:
    """True when all three APNs auth-key fields are non-empty."""
    return bool(
        settings.apns_team_id
        and settings.apns_key_id
        and settings.apns_private_key_pem
    )


def _get_apns_client(settings: Settings, environment: str) -> Any:
    """Return (or lazily create) an aioapns.APNs for the given environment."""
    try:
        import aioapns  # noqa: PLC0415
    except ImportError:
        raise RuntimeError("aioapns is not installed — install with: pip install aioapns>=3.2")

    cache_key = (settings.apns_team_id, settings.apns_key_id, environment)
    if cache_key not in _apns_clients:
        use_sandbox = environment != "production"
        client = aioapns.APNs(
            key=settings.apns_private_key_pem,
            team_id=settings.apns_team_id,
            key_id=settings.apns_key_id,
            use_sandbox=use_sandbox,
        )
        _apns_clients[cache_key] = client
    return _apns_clients[cache_key]


def _apns_topic(settings: Settings, bundle_id: str) -> str:
    """Resolve the APNs topic: per-device bundle_id > settings.apns_topic > settings.apple_bundle_id."""
    if bundle_id:
        return bundle_id
    if settings.apns_topic:
        return settings.apns_topic
    return settings.apple_bundle_id


def summarize_assistant_completion(
    *, tool_calls: list[dict[str, Any]], assistant_markdown: str
) -> str:
    """Build a one-line push body for the AI-finished-thinking notification (M20).

    Strategy: pick the first sentence of the assistant's reply (capped at
    140 chars), or fall back to a tool-count summary when the markdown is
    empty. The full message is always available in the thread when the
    user opens the deep link.
    """
    text = (assistant_markdown or "").strip()
    if text:
        # Trim at the first sentence boundary so the banner reads naturally.
        sentence_end = -1
        for char in (".", "!", "?"):
            idx = text.find(char)
            if idx != -1 and (sentence_end == -1 or idx < sentence_end):
                sentence_end = idx
        if 10 < sentence_end < 140:
            text = text[: sentence_end + 1]
        elif len(text) > 140:
            text = text[:137].rstrip() + "..."
        return text
    successful = [tc for tc in tool_calls if tc.get("ok")]
    if not successful:
        return "Your assistant turn finished."
    if len(successful) == 1:
        name = str(successful[0].get("name") or "")
        if name == "generate_week_plan":
            return "Your week plan is ready."
        return "Your assistant finished an update."
    return f"Your assistant made {len(successful)} updates."


async def send_push(
    session: Session,
    *,
    settings: Settings,
    user_id: str,
    title: str,
    body: str,
    payload: dict[str, Any] | None = None,
    collapse_id: str | None = None,
) -> int:
    """Send a push notification to all active devices for user_id.

    Returns the count of devices successfully delivered (best-effort; APNs
    errors are logged but do not raise). Marks 410 Unregistered devices
    disabled_at so they are not retried.
    """
    if not is_apns_configured(settings):
        logger.debug("send_push: APNs not configured, skipping")
        return 0

    try:
        import aioapns  # noqa: PLC0415
    except ImportError:
        logger.warning("send_push: aioapns not installed")
        return 0

    devices = list(
        session.scalars(
            select(PushDevice).where(
                PushDevice.user_id == user_id,
                PushDevice.disabled_at.is_(None),
            )
        ).all()
    )

    if not devices:
        return 0

    apns_payload: dict[str, Any] = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
        },
    }
    if payload:
        apns_payload.update(payload)

    delivered = 0
    for device in devices:
        try:
            client = _get_apns_client(settings, device.apns_environment)
            topic = _apns_topic(settings, device.bundle_id)
            request = aioapns.NotificationRequest(
                device_token=device.device_token,
                message=apns_payload,
                notification_id=collapse_id,
                collapse_key=collapse_id,
                apns_topic=topic,
            )
            result = await client.send_notification(request)
            if result.is_successful:
                delivered += 1
            elif hasattr(result, "status") and result.status == "Unregistered":
                # APNs 410 — device unregistered; soft-disable so we never retry
                logger.info(
                    "send_push: device unregistered (410) user=%s token=%.12s…",
                    user_id,
                    device.device_token,
                )
                device.disabled_at = utcnow()
            else:
                status = getattr(result, "status", "unknown")
                logger.warning(
                    "send_push: APNs error=%s user=%s token=%.12s…",
                    status,
                    user_id,
                    device.device_token,
                )
        except Exception:
            logger.exception(
                "send_push: exception sending to user=%s token=%.12s…",
                user_id,
                device.device_token,
            )
    return delivered
