"""Product lookup routes for grocery scanning (M11 Phase 4).

Reuses the existing Kroger client; adds a UPC reverse-lookup that the iOS
barcode scanner calls. Lives separately from `/api/stores` so the URL is
self-explanatory at the iOS call site.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/products", tags=["products"])


class ProductLookupRequest(BaseModel):
    upc: str = Field(min_length=8, max_length=20)
    location_id: str = Field(min_length=1)


class ProductLookupResponse(BaseModel):
    product_id: str
    upc: str
    brand: str
    description: str
    package_size: str
    regular_price: float | None = None
    promo_price: float | None = None
    product_url: str
    in_stock: bool


@router.post("/lookup-upc", response_model=ProductLookupResponse)
def lookup_product_by_upc(
    request: ProductLookupRequest,
    _user: CurrentUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
) -> ProductLookupResponse:
    if not settings.kroger_client_id:
        raise HTTPException(
            status_code=503,
            detail=(
                "Kroger API not configured. Set SIMMERSMITH_KROGER_CLIENT_ID and "
                "SIMMERSMITH_KROGER_CLIENT_SECRET."
            ),
        )

    from app.services.kroger import search_product_by_upc

    try:
        match = search_product_by_upc(
            settings, upc=request.upc, location_id=request.location_id
        )
    except Exception as exc:
        logger.warning("Kroger UPC lookup failed: %s", exc)
        raise HTTPException(status_code=502, detail=f"Kroger API error: {exc}") from exc

    if match is None:
        raise HTTPException(
            status_code=404,
            detail=f"No product found for UPC {request.upc} at this store.",
        )
    return ProductLookupResponse(**match)
