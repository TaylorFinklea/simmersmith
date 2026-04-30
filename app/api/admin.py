"""Admin-only diagnostic endpoints. Gated by legacy bearer token."""
from __future__ import annotations

from secrets import compare_digest

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings, get_settings
from app.db import get_session
from app.services.image_usage import global_usage_summary
from sqlalchemy.orm import Session


router = APIRouter(prefix="/api/admin", tags=["admin"])
bearer_scheme = HTTPBearer(auto_error=False)


def require_admin_bearer(
    authorization: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    settings: Settings = Depends(get_settings),
) -> None:
    """Dependency: require a valid legacy bearer token matching SIMMERSMITH_API_TOKEN.

    Raises 403 if the token is missing, invalid, or empty.
    """
    if not settings.api_token.strip():
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin token not configured",
        )
    if authorization is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Missing authorization header",
        )
    if not compare_digest(authorization.credentials, settings.api_token):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid token",
        )


@router.get("/image-usage")
def get_image_usage(
    days: int = Query(30, ge=1, le=365),
    session: Session = Depends(get_session),
    _: None = Depends(require_admin_bearer),
) -> dict:
    """Global image generation telemetry (admin only).

    Returns per-provider aggregates and top users by image count.

    Query parameters:
        days: Window size in days (1-365). Default 30.

    Requires: Bearer token matching SIMMERSMITH_API_TOKEN.
    """
    return global_usage_summary(session, days=days)
