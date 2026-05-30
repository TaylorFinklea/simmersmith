"""F22 regression: Apple JWS verification must validate the x5c chain to
Apple's root, not just trust the leaf key embedded in the token.

A forged transaction signed by an attacker's own key (with their own
self-signed cert in the x5c header) must be rejected — otherwise any
authenticated user could mint a free Pro entitlement.
"""
from __future__ import annotations

import base64
import datetime as dt
import os

import jwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from app.config import get_settings
from app.services.subscriptions import SubscriptionVerificationError, verify_transaction_jws

BUNDLE_ID = "app.simmersmith.test"


@pytest.fixture
def settings():
    os.environ["SIMMERSMITH_APPLE_IAP_BUNDLE_ID"] = BUNDLE_ID
    os.environ["SIMMERSMITH_APPLE_IAP_ENVIRONMENT"] = "Sandbox"
    get_settings.cache_clear()
    yield get_settings()
    os.environ.pop("SIMMERSMITH_APPLE_IAP_BUNDLE_ID", None)
    os.environ.pop("SIMMERSMITH_APPLE_IAP_ENVIRONMENT", None)
    get_settings.cache_clear()


def _forged_jws() -> str:
    """A fully attacker-controlled JWSTransaction: own keypair, own
    self-signed cert in x5c, correct-looking claims."""
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Totally Apple Honest")])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=365))
        .sign(key, hashes.SHA256())
    )
    cert_der = cert.public_bytes(serialization.Encoding.DER)
    priv_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return jwt.encode(
        {
            "bundleId": BUNDLE_ID,
            "productId": "simmersmith.pro.annual",
            "originalTransactionId": "forged-1",
            "transactionId": "forged-1",
            "purchaseDate": 1_700_000_000_000,
            "expiresDate": 1_900_000_000_000,
            "environment": "Sandbox",
        },
        priv_pem,
        algorithm="ES256",
        headers={"x5c": [base64.b64encode(cert_der).decode("ascii")]},
    )


def test_forged_self_signed_jws_is_rejected(settings) -> None:
    with pytest.raises(SubscriptionVerificationError):
        verify_transaction_jws(_forged_jws(), settings)


def test_garbage_token_is_rejected(settings) -> None:
    with pytest.raises(SubscriptionVerificationError):
        verify_transaction_jws("not-a-jws", settings)


def test_missing_bundle_id_config_is_rejected() -> None:
    os.environ.pop("SIMMERSMITH_APPLE_IAP_BUNDLE_ID", None)
    get_settings.cache_clear()
    try:
        with pytest.raises(SubscriptionVerificationError):
            verify_transaction_jws(_forged_jws(), get_settings())
    finally:
        get_settings.cache_clear()
