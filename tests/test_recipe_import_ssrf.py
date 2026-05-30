"""F28 regression: recipe-import URL fetch must reject hosts that resolve
to private/internal addresses, including DNS names (not just IP literals)
and redirect targets."""
from __future__ import annotations

import pytest

from app.services.recipe_import.parser import _assert_public_url, import_recipe_from_url


@pytest.mark.parametrize(
    "url",
    [
        "http://localhost/recipe",                    # DNS name -> loopback
        "http://127.0.0.1/recipe",                    # loopback literal
        "http://169.254.169.254/latest/meta-data/",   # cloud metadata (link-local)
        "http://[::1]/recipe",                        # ipv6 loopback
        "http://10.0.0.5/internal",                   # RFC-1918 private
    ],
)
def test_internal_targets_rejected_at_assert(url) -> None:
    with pytest.raises(ValueError):
        _assert_public_url(url)


@pytest.mark.parametrize("scheme_url", ["ftp://example.com/x", "file:///etc/passwd"])
def test_non_http_schemes_rejected(scheme_url) -> None:
    with pytest.raises(ValueError):
        _assert_public_url(scheme_url)


def test_import_from_url_rejects_internal_host() -> None:
    # End-to-end: the fetch path refuses before making the request.
    with pytest.raises(ValueError):
        import_recipe_from_url("http://localhost:9999/recipe")


def test_pinned_connect_url_rewrites_host_to_ip() -> None:
    from app.services.recipe_import.parser import _pinned_connect_url

    assert _pinned_connect_url("https://example.com/recipe?a=1", "93.184.216.34") == (
        "https://93.184.216.34/recipe?a=1"
    )
    # Non-default port preserved.
    assert _pinned_connect_url("http://example.com:8080/x", "10.0.0.1") == (
        "http://10.0.0.1:8080/x"
    )
    # IPv6 gets bracketed.
    assert _pinned_connect_url("https://example.com/p", "2606:2800:220:1:248:1893:25c8:1946") == (
        "https://[2606:2800:220:1:248:1893:25c8:1946]/p"
    )
