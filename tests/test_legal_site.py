from __future__ import annotations

from html.parser import HTMLParser
from pathlib import Path
import unittest
from urllib.parse import urlsplit


DOCS_ROOT = Path(__file__).parents[1] / "docs"
PAGE_PATHS = {
    "home": DOCS_ROOT / "index.html",
    "support": DOCS_ROOT / "support" / "index.html",
    "privacy": DOCS_ROOT / "privacy" / "index.html",
    "terms": DOCS_ROOT / "terms" / "index.html",
}


class _NavigationParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.in_navigation = False
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "nav":
            self.in_navigation = True
        elif tag == "a" and self.in_navigation and attributes.get("href"):
            self.links.append(attributes["href"])

    def handle_endtag(self, tag: str) -> None:
        if tag == "nav":
            self.in_navigation = False


def _navigation_links(page: Path) -> list[str]:
    parser = _NavigationParser()
    parser.feed(page.read_text())
    return parser.links


def _resolved_local_page(source: Path, href: str) -> Path | None:
    split = urlsplit(href)
    if split.scheme or split.netloc or href.startswith("mailto:"):
        return None

    target = (source.parent / split.path).resolve()
    if split.path.endswith("/") or target.is_dir():
        target /= "index.html"
    return target


class LegalSiteTests(unittest.TestCase):
    def test_legal_pages_are_present(self) -> None:
        self.assertTrue(PAGE_PATHS["privacy"].is_file())
        self.assertTrue(PAGE_PATHS["terms"].is_file())

    def test_every_page_navigation_links_to_support_privacy_and_terms(self) -> None:
        for page in PAGE_PATHS.values():
            with self.subTest(page=page):
                links = _navigation_links(page)
                resolved = {
                    target
                    for href in links
                    if (target := _resolved_local_page(page, href)) is not None
                }
                self.assertIn(PAGE_PATHS["support"].resolve(), resolved)
                self.assertIn(PAGE_PATHS["privacy"].resolve(), resolved)
                self.assertIn(PAGE_PATHS["terms"].resolve(), resolved)

    def test_every_local_navigation_target_exists(self) -> None:
        for page in PAGE_PATHS.values():
            for href in _navigation_links(page):
                target = _resolved_local_page(page, href)
                if target is not None:
                    self.assertTrue(
                        target.is_file(),
                        f"{page}: {href} resolves to missing {target}",
                    )


if __name__ == "__main__":
    unittest.main()
