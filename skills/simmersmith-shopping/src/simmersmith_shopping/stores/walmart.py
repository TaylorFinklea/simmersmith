"""Walmart web store driver.

Walmart's site is React-heavy with anti-bot signals; using a real
Playwright persistent profile (cookies + storage) is essential. The
selectors here track Walmart's stable `data-testid` attributes; if
the page renders product cards differently in your account region,
edit `_SELECTORS`.
"""
from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from .base import ProductCandidate, StoreHandler, locate


if TYPE_CHECKING:
    from playwright.sync_api import BrowserContext

    from ..parser import GroceryLine


log = logging.getLogger(__name__)


_SELECTORS = {
    "search_input": "input[name='q']",
    "product_card": "[data-testid='item-stack'] [data-testid='list-view']",
    "card_title": "span[data-automation-id='product-title']",
    "card_price": "div[data-automation-id='product-price']",
    "card_link": "a[link-identifier]",
    "add_to_cart": "button[data-automation-id='atc']",
}


class WalmartHandler(StoreHandler):
    @property
    def slug(self) -> str:
        return "walmart"

    @property
    def display_name(self) -> str:
        return "Walmart"

    @property
    def default_login_url(self) -> str:
        return "https://www.walmart.com/account/login"

    def search_products(self, context: "BrowserContext", line: "GroceryLine") -> list[ProductCandidate]:
        if not line.name:
            return []
        page = context.new_page()
        try:
            page.goto(f"https://www.walmart.com/search?q={line.name}", wait_until="domcontentloaded")
            locate(page, _SELECTORS, "product_card", store=self.slug, where="search results")
            cards = page.query_selector_all(_SELECTORS["product_card"])[:3]
            results: list[ProductCandidate] = []
            for card in cards:
                title_el = card.query_selector(_SELECTORS["card_title"])
                price_el = card.query_selector(_SELECTORS["card_price"])
                link_el = card.query_selector(_SELECTORS["card_link"])
                if not title_el or not price_el:
                    continue
                price = _parse_walmart_price(price_el.inner_text())
                if price is None:
                    continue
                href = link_el.get_attribute("href") if link_el else ""
                if href and href.startswith("/"):
                    href = "https://www.walmart.com" + href
                results.append(ProductCandidate(
                    store=self.slug,
                    title=title_el.inner_text().strip(),
                    unit_price=price,
                    available=True,
                    product_url=href or "",
                ))
            return results
        except Exception as exc:
            log.warning("walmart search for %r failed: %s", line.name, exc)
            return []
        finally:
            page.close()

    def add_to_cart(self, context: "BrowserContext", candidate: ProductCandidate) -> None:
        if not candidate.product_url:
            raise RuntimeError("Walmart candidate missing product_url; can't add to cart.")
        page = context.new_page()
        try:
            page.goto(candidate.product_url, wait_until="domcontentloaded")
            locate(page, _SELECTORS, "add_to_cart", store=self.slug, where="product page", timeout_ms=10000).click(timeout=10000)
            page.wait_for_timeout(800)
        finally:
            page.close()


def _parse_walmart_price(text: str) -> float | None:
    """Walmart price elements often render as 'current price$3.48' or
    '$3.48 / fl oz'. Strip everything except the dollar amount."""
    import re

    match = re.search(r"\$([\d,.]+)", text)
    if not match:
        return None
    try:
        return float(match.group(1).replace(",", ""))
    except ValueError:
        return None
