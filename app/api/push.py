"""Push notification device registration + test endpoints (M18)."""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings
from app.db import get_session
from app.models._base import new_id, utcnow
from app.models.push import PushDevice
from app.services.push_apns import is_apns_configured, send_push

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/push", tags=["push"])


# ── Request/response models ──────────────────────────────────────────


class RegisterDeviceRequest(BaseModel):
    device_token: str
    environment: str = "sandbox"
    bundle_id: str = ""


class RegisterDeviceResponse(BaseModel):
    registered: bool


class TestPushRequest(BaseModel):
    user_id: str
    title: str
    body: str


class TestPushResponse(BaseModel):
    delivered: int


# ── Routes ──────────────────────────────────────────────────────────


@router.post("/devices", response_model=RegisterDeviceResponse)
def register_device(
    payload: RegisterDeviceRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Register or refresh a device token for the authenticated user.

    Uses an upsert: if a row already exists for (user_id, device_token)
    it refreshes last_seen_at and clears disabled_at; otherwise a new
    row is inserted. This matches the iOS behaviour of calling this
    endpoint on every app launch with the same token.
    """
    token = payload.device_token.strip()
    if not token:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="device_token required")

    existing = session.scalar(
        select(PushDevice).where(
            PushDevice.user_id == current_user.id,
            PushDevice.device_token == token,
        )
    )
    now = utcnow()
    if existing is not None:
        existing.last_seen_at = now
        existing.disabled_at = None
        existing.apns_environment = payload.environment
        existing.bundle_id = payload.bundle_id
        existing.updated_at = now
    else:
        session.add(
            PushDevice(
                id=new_id(),
                user_id=current_user.id,
                device_token=token,
                platform="ios",
                apns_environment=payload.environment,
                bundle_id=payload.bundle_id,
                last_seen_at=now,
                disabled_at=None,
                created_at=now,
                updated_at=now,
            )
        )
    session.commit()
    return {"registered": True}


@router.delete("/devices/{device_token}", status_code=status.HTTP_204_NO_CONTENT)
def unregister_device(
    device_token: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> None:
    """Soft-disable a device token (e.g. on sign-out)."""
    device = session.scalar(
        select(PushDevice).where(
            PushDevice.user_id == current_user.id,
            PushDevice.device_token == device_token,
        )
    )
    if device is not None:
        device.disabled_at = utcnow()
        session.commit()


@router.post("/test", response_model=TestPushResponse)
async def test_push(
    payload: TestPushRequest,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Admin-only: send a test push to any user_id.

    Gated by the legacy API token (same check as MCP endpoints). Used
    to validate APNs credentials end-to-end without waiting for a
    scheduler tick.
    """
    # Allow if the caller used the legacy bearer token (which maps to
    # local_user_id). In production the legacy api_token is the admin
    # credential, so check that the caller IS the local user.
    if current_user.id != settings.local_user_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin-only endpoint — authenticate with the legacy API token",
        )

    if not is_apns_configured(settings):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="APNs not configured — set SIMMERSMITH_APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY_PEM",
        )

    delivered = await send_push(
        session,
        settings=settings,
        user_id=payload.user_id,
        title=payload.title,
        body=payload.body,
    )
    return {"delivered": delivered}
