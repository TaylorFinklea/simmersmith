"""M16: provider email persisted only when not explicitly unverified."""
from __future__ import annotations

from app.api.auth import _verified_email


def test_keeps_email_when_verified_bool_true() -> None:
    assert _verified_email({"email": "a@x.com", "email_verified": True}) == "a@x.com"


def test_keeps_email_when_verified_string_true() -> None:
    assert _verified_email({"email": "a@x.com", "email_verified": "true"}) == "a@x.com"


def test_drops_email_when_explicitly_unverified() -> None:
    assert _verified_email({"email": "a@x.com", "email_verified": False}) == ""
    assert _verified_email({"email": "a@x.com", "email_verified": "false"}) == ""


def test_keeps_email_when_claim_absent() -> None:
    # Some flows omit the claim; email is display-only + keyed on sub.
    assert _verified_email({"email": "a@x.com"}) == "a@x.com"
