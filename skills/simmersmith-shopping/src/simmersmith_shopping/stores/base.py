"""Per-store handler interface + Playwright profile helpers shared by
every retailer driver.
"""
from __future__ import annotations

import os
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING


if TYPE_CHECKING:
    from playwright.sync_api import BrowserContext

    from ..parser import GroceryLine


def profile_root() -> Path:
    """Directory holding per-store Playwright persistent profiles. Each
    store gets its own subdirectory so a cookie collision in one
    retailer never leaks into another."""
    base = Path(os.environ.get("SIMMERSMITH_PROFILE_ROOT") or "~/.config/simmersmith/skill-profile").expanduser()
    base.mkdir(parents=True, exist_ok=True)
    return base


@dataclass(frozen=True, slots=True)
class ProductCandidate:
    """One product the store can sell to fulfil a grocery line.
    `unit_price` is per-pack / per-item; the splitter treats this as
    the cost of the line. `package_size` is shown in the summary."""
    store: str
    title: str
    unit_price: float
    package_size: str = ""
    available: bool = True
    product_url: str = ""


class StoreHandler(ABC):
    """Abstract base for a per-store Playwright driver.

    Subclasses implement four methods:
    - `slug` — short identifier used in CLI flags and config.
    - `display_name` — human-readable label for summaries.
    - `default_login_url` — opened in interactive `login` mode.
    - `search_products(context, line)` — return the top product
      candidates for a parsed grocery line. Empty list means
      "we can't fulfil this".
    - `add_to_cart(context, candidate)` — drive the cart UI to add
      one unit of `candidate`. Raises if the cart-add fails so the
      orchestrator can surface a per-store error.
    """

    @property
    @abstractmethod
    def slug(self) -> str: ...

    @property
    @abstractmethod
    def display_name(self) -> str: ...

    @property
    @abstractmethod
    def default_login_url(self) -> str: ...

    def profile_path(self) -> Path:
        path = profile_root() / self.slug
        path.mkdir(parents=True, exist_ok=True)
        return path

    @abstractmethod
    def search_products(
        self,
        context: "BrowserContext",
        line: "GroceryLine",
    ) -> list[ProductCandidate]:
        """Top product candidates for the parsed grocery line. Should
        return at most ~3 — the splitter only consumes the cheapest
        per-store row."""

    @abstractmethod
    def add_to_cart(
        self,
        context: "BrowserContext",
        candidate: ProductCandidate,
    ) -> None:
        """Add the candidate to the user's cart. Raises if the click
        fails (network error, sold out at submit time, etc)."""
