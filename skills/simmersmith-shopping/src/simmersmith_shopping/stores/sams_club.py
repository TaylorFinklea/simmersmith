"""Sam's Club stub.

Login flow works (Playwright persistent profile + the URL below),
but `search_products` and `add_to_cart` are intentionally stubbed —
Sam's Club requires per-region store selection and SSO that's
finicky to script. To complete:

1. After `login --store sams_club` saves cookies, dogfood a search
   manually in the same Playwright window and inspect the DOM.
2. Replace `_SELECTORS` with the real `data-testid` values you see.
3. Implement `search_products` matching the Aldi / Walmart pattern.
4. Implement `add_to_cart` clicking the green ADD button.

Until then, the splitter never picks Sam's Club because
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


class SamsClubHandler(StoreHandler):
    @property
    def slug(self) -> str:
        return "sams_club"

    @property
    def display_name(self) -> str:
        return "Sam's Club"

    @property
    def default_login_url(self) -> str:
        return "https://www.samsclub.com/login"

    def search_products(self, context: "BrowserContext", line: "GroceryLine") -> list[ProductCandidate]:
        log.debug("sams_club: stub search_products called; returning empty list")
        return []

    def add_to_cart(self, context: "BrowserContext", candidate: ProductCandidate) -> None:
        raise NotImplementedError(
            "Sam's Club cart-add is unimplemented. See the docstring at "
            "the top of this file for completion steps."
        )
