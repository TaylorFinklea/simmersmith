"""Instacart driver.

The driver shape is complete — `search_products` and `add_to_cart`
mirror Aldi/Walmart — but `_SELECTORS` ships empty because
Instacart's selector set is storefront-specific (the H-E-B
storefront and the Aldi-via-Instacart storefront render different
component trees) and has to be captured against an authenticated
profile.

**To finish wiring this store up:**

1. One-time login (saves cookies under the persistent profile):

       uv run --project ~/.claude/skills/simmersmith-shopping \\
         python -m simmersmith_shopping login --store instacart

   Sign in and pick the storefront you actually shop. The
   persistent profile remembers it.

2. Capture selectors against a live search + ADD interaction:

       uv run --project ~/.claude/skills/simmersmith-shopping \\
         python -m simmersmith_shopping capture --store instacart

3. Fill in the `_SELECTORS` dict below using the candidates file.
   Priority order: `data-testid` first, ARIA label second,
   role-based third, brittle CSS class last.

If the storefront changes (different retailer, different region),
re-run capture — Instacart re-namespaces some testids per
storefront.

Until `_SELECTORS` is populated, the splitter never picks
Instacart because `search_products` returns an empty list and logs
a one-time hint pointing back at this docstring.
"""
from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from .base import ProductCandidate, StoreHandler, locate


if TYPE_CHECKING:
    from playwright.sync_api import BrowserContext

    from ..parser import GroceryLine


log = logging.getLogger(__name__)


# Empty until `capture --store instacart` is run + author transcribes
# the candidates. See module docstring for the workflow.
_SELECTORS: dict[str, str] = {
    # "search_input":  "",
    # "product_card":  "",
    # "card_title":    "",
    # "card_price":    "",
    # "card_link":     "",
    # "add_to_cart":   "",
}


_NEEDS_CAPTURE_LOGGED = False


def _hint_needs_capture() -> None:
    global _NEEDS_CAPTURE_LOGGED
    if _NEEDS_CAPTURE_LOGGED:
        return
    log.warning(
        "instacart: _SELECTORS empty — run `capture --store instacart` and fill "
        "the dict in instacart.py. See module docstring."
    )
    _NEEDS_CAPTURE_LOGGED = True


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
        if not _SELECTORS:
            _hint_needs_capture()
            return []
        if not line.name:
            return []
        page = context.new_page()
        try:
            page.goto(f"https://www.instacart.com/store/s?k={line.name}", wait_until="domcontentloaded")
            locate(page, _SELECTORS, "product_card", store=self.slug, where="search results")
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
                href = link_el.get_attribute("href") if link_el else ""
                if href and href.startswith("/"):
                    href = "https://www.instacart.com" + href
                results.append(ProductCandidate(
                    store=self.slug,
                    title=title_el.inner_text().strip(),
                    unit_price=price,
                    available=True,
                    product_url=href or "",
                ))
            return results
        except Exception as exc:
            log.warning("instacart search for %r failed: %s", line.name, exc)
            return []
        finally:
            page.close()

    def add_to_cart(self, context: "BrowserContext", candidate: ProductCandidate) -> None:
        if not _SELECTORS:
            raise RuntimeError(
                "instacart: _SELECTORS empty — run capture + fill the map "
                "(see top of instacart.py)."
            )
        if not candidate.product_url:
            raise RuntimeError("Instacart candidate missing product_url; can't add to cart.")
        page = context.new_page()
        try:
            page.goto(candidate.product_url, wait_until="domcontentloaded")
            locate(page, _SELECTORS, "add_to_cart", store=self.slug, where="product page", timeout_ms=10000).click(timeout=10000)
            page.wait_for_timeout(800)
        finally:
            page.close()


def _parse_price(text: str) -> float | None:
    """Instacart price elements often look like '$4.99' or '$4.99 each'
    or '$4.99/lb'. Pick the first dollar-looking number."""
    import re

    match = re.search(r"\$([\d,]+\.\d{2})", text)
    if not match:
        return None
    try:
        return float(match.group(1).replace(",", ""))
    except ValueError:
        return None
