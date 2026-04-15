"""Store search endpoints for grocery pricing."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query

from app.auth import CurrentUser, get_current_user
from app.config import get_settings

router = APIRouter(prefix="/api/stores", tags=["stores"])


@router.get("/search")
def search_stores(
    zip_code: str = Query(..., min_length=5, max_length=10, description="US zip code"),
    radius: int = Query(10, ge=1, le=50, description="Search radius in miles"),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict]:
    """Search for Kroger-family stores near a zip code."""
    from app.services.kroger import search_locations

    settings = get_settings()
    if not settings.kroger_client_id:
        raise HTTPException(
            status_code=503,
            detail="Kroger API not configured. Set SIMMERSMITH_KROGER_CLIENT_ID and SIMMERSMITH_KROGER_CLIENT_SECRET.",
        )

    try:
        return search_locations(settings, zip_code=zip_code, radius_miles=radius)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Kroger API error: {exc}") from exc
