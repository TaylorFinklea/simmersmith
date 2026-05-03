"""Per-retailer Playwright drivers. Each store exposes a
`StoreHandler` instance via the registry below; the CLI orchestrator
calls `search_products` to gather price candidates and `add_to_cart`
to drive the cart-fill phase.
"""
from __future__ import annotations

from .aldi import AldiHandler
from .base import StoreHandler, ProductCandidate
from .instacart import InstacartHandler
from .sams_club import SamsClubHandler
from .walmart import WalmartHandler


REGISTRY: dict[str, StoreHandler] = {
    "aldi": AldiHandler(),
    "walmart": WalmartHandler(),
    "sams_club": SamsClubHandler(),
    "instacart": InstacartHandler(),
}


__all__ = [
    "REGISTRY",
    "StoreHandler",
    "ProductCandidate",
    "AldiHandler",
    "WalmartHandler",
    "SamsClubHandler",
    "InstacartHandler",
]
