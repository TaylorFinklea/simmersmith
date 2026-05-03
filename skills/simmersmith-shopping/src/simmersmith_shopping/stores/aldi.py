"""Aldi web store driver.

Aldi's site (`new.aldi.us`) puts the search box on the home page; product
pages have an `Add to cart` button that surfaces a side-cart drawer.
The selectors below are best-effort — Aldi A/B-tests; if a run fails,
edit `_SELECTORS` and re-run.
"""
from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from .base import ProductCandidate, StoreHandler


if TYPE_CHECKING:
    from playwright.sync_api import BrowserContext

    from ..parser import GroceryLine


log = logging.getLogger(__name__)


_SELECTORS = {
    "search_input": "input[type='search']",
    "product_card": "[data-testid='product-tile']",
    "card_title": "[data-testid='product-tile-title']",
    "card_price": "[data-testid='product-price']",
    "card_link": "a[href*='/product/']",
    "add_to_cart": "button[aria-label*='Add' i]",
}


class AldiHandler(StoreHandler):
    @property
    def slug(self) -> str:
        return "aldi"

    @property
    def display_name(self) -> str:
        return "Aldi"

    @property
    def default_login_url(self) -> str:
        return "https://new.aldi.us/sign-in"

    def search_products(self, context: "BrowserContext", line: "GroceryLine") -> list[ProductCandidate]:
        if not line.name:
            return []
        page = context.new_page()
        try:
            page.goto(f"https://new.aldi.us/results?q={line.name}", wait_until="domcontentloaded")
            page.wait_for_selector(_SELECTORS["product_card"], timeout=8000)
            cards = page.query_selector_all(_SELECTORS["product_card"])[:3]
            results: list[ProductCandidate] = []
            for card in cards:
                title_el = card.query_selector(_SELECTORS["card_title"])
                price_el = card.query_selector(_SELECTORS["card_price"])
                link_el = card.query_selector(_SELECTORS["card_link"])
                if not title_el or not price_el:
                    continue
                price = _parse_price(price_el.inner_text())
                if price is None:
                    continue
                results.append(ProductCandidate(
                    store=self.slug,
                    title=title_el.inner_text().strip(),
                    unit_price=price,
                    available=True,
                    product_url=("https://new.aldi.us" + link_el.get_attribute("href")) if link_el else "",
                ))
            return results
        except Exception as exc:
            log.warning("aldi search for %r failed: %s", line.name, exc)
            return []
        finally:
            page.close()

    def add_to_cart(self, context: "BrowserContext", candidate: ProductCandidate) -> None:
        if not candidate.product_url:
            raise RuntimeError("Aldi candidate missing product_url; can't add to cart.")
        page = context.new_page()
        try:
            page.goto(candidate.product_url, wait_until="domcontentloaded")
            page.click(_SELECTORS["add_to_cart"], timeout=8000)
            # Aldi animates the side-cart in; give it a beat to settle
            # so an immediate next add_to_cart sees a stable DOM.
            page.wait_for_timeout(800)
        finally:
            page.close()


def _parse_price(text: str) -> float | None:
    cleaned = text.strip().replace("$", "").replace(",", "")
    cleaned = cleaned.split()[0] if cleaned else cleaned
    try:
        return float(cleaned)
    except ValueError:
        return None
