"""import-vision lane — backend bug-bash fixes (2026-06-13).

#52 recipe-image upload stored an arbitrary Content-Type + arbitrary bytes and
    served them back un-sniffed (stored content-type / XSS). Now: MIME allow-list
    + magic-byte sniff on upload, nosniff + inline disposition on fetch.
#53 SSRF allow-list let RFC 6598 CGNAT space (100.64.0.0/10) through.
T7  vision provider httpx/shape errors now wrap into a clean AIProviderError
    (no raw upstream URL/body leaking through the route's detail=str(exc)).
"""
from __future__ import annotations

import base64

import httpx
import pytest

from app.services.recipe_image_ai import sniff_image_mime, validate_upload_image
from app.services.recipe_import.parser import _is_blocked_ip
from app.services.vision_ai import AIProviderError


# Minimal valid magic-byte headers for each supported format.
_PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16
_JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 16
_GIF = b"GIF89a" + b"\x00" * 16
_WEBP = b"RIFF\x00\x00\x00\x00WEBP" + b"\x00" * 8
_HTML = b"<script>alert(document.domain)</script>"


def _create_recipe(client) -> str:
    resp = client.post(
        "/api/recipes",
        json={
            "name": "Image Test Recipe",
            "meal_type": "dinner",
            "servings": 2,
            "ingredients": [],
            "steps": [{"instruction": "Cook it."}],
        },
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["recipe_id"]


# ── #52 — upload MIME allow-list + magic-byte sniffing ────────────────


def test_sniff_image_mime_recognizes_supported_formats() -> None:
    assert sniff_image_mime(_PNG) == "image/png"
    assert sniff_image_mime(_JPEG) == "image/jpeg"
    assert sniff_image_mime(_GIF) == "image/gif"
    assert sniff_image_mime(_WEBP) == "image/webp"
    assert sniff_image_mime(_HTML) is None


def test_validate_upload_image_accepts_jpg_alias() -> None:
    # 'image/jpg' is a common (non-canonical) alias clients send.
    assert validate_upload_image(_JPEG, "image/jpg") == "image/jpeg"


def test_validate_upload_image_rejects_non_image_mime() -> None:
    with pytest.raises(ValueError):
        validate_upload_image(_PNG, "text/html")


def test_validate_upload_image_rejects_bytes_not_an_image() -> None:
    with pytest.raises(ValueError):
        validate_upload_image(_HTML, "image/png")


def test_validate_upload_image_rejects_declared_content_mismatch() -> None:
    with pytest.raises(ValueError):
        validate_upload_image(_JPEG, "image/png")


def test_upload_route_rejects_html_disguised_as_image(client) -> None:
    recipe_id = _create_recipe(client)
    payload = base64.b64encode(_HTML).decode("ascii")
    resp = client.put(
        f"/api/recipes/{recipe_id}/image",
        json={"image_base64": payload, "mime_type": "text/html"},
    )
    assert resp.status_code == 400


def test_upload_route_rejects_png_declared_html_bytes(client) -> None:
    recipe_id = _create_recipe(client)
    payload = base64.b64encode(_HTML).decode("ascii")
    resp = client.put(
        f"/api/recipes/{recipe_id}/image",
        json={"image_base64": payload, "mime_type": "image/png"},
    )
    assert resp.status_code == 400


def test_upload_then_fetch_sets_nosniff_and_inline(client) -> None:
    recipe_id = _create_recipe(client)
    payload = base64.b64encode(_PNG).decode("ascii")
    up = client.put(
        f"/api/recipes/{recipe_id}/image",
        json={"image_base64": payload, "mime_type": "image/png"},
    )
    assert up.status_code == 200, up.text

    got = client.get(f"/api/recipes/{recipe_id}/image")
    assert got.status_code == 200
    assert got.headers["content-type"].startswith("image/png")
    assert got.headers["x-content-type-options"] == "nosniff"
    assert got.headers["content-disposition"] == "inline"
    assert got.content == _PNG


# ── #53 — SSRF allow-list rejects RFC 6598 CGNAT space ────────────────


def test_cgnat_range_is_blocked() -> None:
    import ipaddress

    assert _is_blocked_ip(ipaddress.ip_address("100.64.0.1")) is True
    assert _is_blocked_ip(ipaddress.ip_address("100.127.255.254")) is True
    # IPv4-mapped IPv6 form of a CGNAT address must also be rejected.
    assert _is_blocked_ip(ipaddress.ip_address("::ffff:100.64.0.1")) is True


def test_public_addresses_still_allowed() -> None:
    import ipaddress

    # Just outside 100.64.0.0/10, and ordinary public hosts.
    assert _is_blocked_ip(ipaddress.ip_address("100.128.0.1")) is False
    assert _is_blocked_ip(ipaddress.ip_address("8.8.8.8")) is False
    assert _is_blocked_ip(ipaddress.ip_address("2606:4700:4700::1111")) is False


def test_loopback_and_private_still_blocked() -> None:
    import ipaddress

    assert _is_blocked_ip(ipaddress.ip_address("127.0.0.1")) is True
    assert _is_blocked_ip(ipaddress.ip_address("10.0.0.1")) is True
    assert _is_blocked_ip(ipaddress.ip_address("169.254.169.254")) is True


# ── T7 — vision provider errors wrap cleanly (no URL/body leak) ───────


def test_vision_provider_http_error_wraps_without_leaking_url(monkeypatch) -> None:
    from app.config import get_settings
    from app.services import vision_ai

    settings = get_settings()
    user_settings = {"ai_direct_provider": "openai"}

    monkeypatch.setattr(
        vision_ai,
        "_resolve_target",
        lambda *a, **k: vision_ai._Target(provider_name="openai", model="gpt-test"),
    )
    monkeypatch.setattr(
        vision_ai,
        "resolve_direct_api_key",
        lambda *a, **k: "sk-test",
    )

    class _RaisingClient:
        def __init__(self, *a, **k) -> None:
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a) -> None:
            return None

        def post(self, *a, **k):
            raise httpx.ConnectTimeout(
                "timed out connecting to https://api.openai.com/v1/chat/completions"
            )

    monkeypatch.setattr(vision_ai.httpx, "Client", _RaisingClient)

    with pytest.raises(AIProviderError) as excinfo:
        vision_ai.identify_ingredient(
            image_bytes=_JPEG,
            mime_type="image/jpeg",
            settings=settings,
            user_settings=user_settings,
        )
    message = str(excinfo.value)
    assert "api.openai.com" not in message
    assert "temporarily unavailable" in message


def test_vision_provider_shape_error_wraps_cleanly(monkeypatch) -> None:
    from app.config import get_settings
    from app.services import vision_ai

    settings = get_settings()
    user_settings = {"ai_direct_provider": "openai"}

    monkeypatch.setattr(
        vision_ai,
        "_resolve_target",
        lambda *a, **k: vision_ai._Target(provider_name="openai", model="gpt-test"),
    )
    monkeypatch.setattr(
        vision_ai,
        "resolve_direct_api_key",
        lambda *a, **k: "sk-test",
    )

    class _Resp:
        def raise_for_status(self) -> None:
            return None

        def json(self) -> dict:
            return {"unexpected": "shape"}

    class _OkClient:
        def __init__(self, *a, **k) -> None:
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a) -> None:
            return None

        def post(self, *a, **k):
            return _Resp()

    monkeypatch.setattr(vision_ai.httpx, "Client", _OkClient)

    with pytest.raises(AIProviderError) as excinfo:
        vision_ai.identify_ingredient(
            image_bytes=_JPEG,
            mime_type="image/jpeg",
            settings=settings,
            user_settings=user_settings,
        )
    assert "unexpected response" in str(excinfo.value)
