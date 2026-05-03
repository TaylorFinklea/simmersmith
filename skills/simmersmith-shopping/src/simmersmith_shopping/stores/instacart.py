"""Instacart stub.

Instacart's web UI is heavily JS-rendered with frequent A/B tests
and a customer-zone-specific catalog. Login flow works (Playwright
persistent profile keeps the auth token), but `search_products`
and `add_to_cart` need real selectors.

To complete:
1. After `login --store instacart` saves cookies, manually run a
   search in the Playwright window and inspect the DOM.
2. Note that Instacart sometimes prefers the GraphQL `/api/...` path
   over scraping — if the network tab shows a clean JSON endpoint,
   switching to httpx may be simpler than DOM scraping.
3. Implement `search_products` and `add_to_cart` matching the
   Aldi / Walmart pattern.

Until then, the splitter never picks Instacart because
`search_products` returns `[]`.
"""
from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from .base import ProductCandidate, StoreHandler


if TYPE_CHECKING:
    from playwright.sync_api import BrowserContext

    from ..parser import GroceryLine


log = logging.getLogger(__name__)


class InstacartHandler(StoreHandler):
    @property
    def slug(self) -> str:
        return "instacart"

    @property
    def display_name(self) -> str:
        return "Instacart"

    @property
    def default_login_url(self) -> str:
        return "https://www.instacart.com/login"

    def search_products(self, context: "BrowserContext", line: "GroceryLine") -> list[ProductCandidate]:
        log.debug("instacart: stub search_products called; returning empty list")
        return []

    def add_to_cart(self, context: "BrowserContext", candidate: ProductCandidate) -> None:
        raise NotImplementedError(
            "Instacart cart-add is unimplemented. See the docstring at "
            "the top of this file for completion steps."
        )
