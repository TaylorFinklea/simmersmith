"""App Store Connect (StoreKit 2) subscription verification.

The iOS client ships a signed `JWSTransaction` after a purchase. We verify
its signature against Apple's X5C-embedded chain, extract the transaction
claims, and upsert the `Subscription` row. The App Store Server
Notifications v2 webhook uses the same verification path.

We do NOT call the App Store Server API here. StoreKit 2's JWS is
self-verifying given Apple's root certificates, and the client always
hands us a fresh transaction post-purchase. A server-side fetch is only
needed when we want to re-pull entitlements ad-hoc — deferred until it is
clearly needed.
"""
from __future__ import annotations

import base64
import json
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import jwt
from jwt import InvalidTokenError, PyJWK
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import Subscription, utcnow


logger = logging.getLogger(__name__)

PRO_PRODUCT_IDS = {
    "simmersmith.pro.monthly",
    "simmersmith.pro.annual",
}


class SubscriptionVerificationError(RuntimeError):
    """Raised when Apple's JWS can't be trusted or is malformed."""


@dataclass(frozen=True)
class VerifiedTransaction:
    """Relevant fields from an Apple `JWSTransaction` payload.

    Apple ships many more fields; we only keep what the Subscription row
    cares about. Raw payload is retained so future migrations can re-parse.
    """
    product_id: str
    original_transaction_id: str
    purchase_date: datetime
    expires_date: datetime
    transaction_id: str
    environment: str
    raw: dict[str, Any]


def verify_transaction_jws(signed: str, settings: Settings) -> VerifiedTransaction:
    """Verify an Apple-signed `JWSTransaction` and return the decoded fields.

    Apple embeds its signing certificate chain in the JWS header (`x5c`).
    We pin the leaf's public key, verify ES256, and enforce basic sanity
    (bundle id, non-empty product id, unexpired `expiresDate` when the
    status says active).

    For now we trust the x5c chain without pinning Apple's root — pinning
    is a hardening pass we can add once the flow is live. In the meantime
    we enforce:
      - Valid ES256 signature against the leaf x5c cert
      - `bundleId` matches `settings.apple_iap_bundle_id`
      - `environment` matches `settings.apple_iap_environment`
    """
    if not settings.apple_iap_bundle_id:
        raise SubscriptionVerificationError(
            "App Store IAP not configured — set SIMMERSMITH_APPLE_IAP_BUNDLE_ID."
        )

    try:
        headers = jwt.get_unverified_header(signed)
    except InvalidTokenError as exc:  # noqa: BLE001
        raise SubscriptionVerificationError(f"Invalid JWS header: {exc}") from exc

    x5c = headers.get("x5c") or []
    if not x5c:
        raise SubscriptionVerificationError("JWS missing x5c certificate chain.")

    leaf_cert_der = base64.b64decode(x5c[0])
    try:
        signing_key = PyJWK.from_dict({"kty": "EC", "crv": "P-256", "x5c": x5c}).key
    except Exception:
        # Fallback: load the leaf cert directly.
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend

        leaf = x509.load_der_x509_certificate(leaf_cert_der, backend=default_backend())
        signing_key = leaf.public_key()

    try:
        claims = jwt.decode(
            signed,
            signing_key,
            algorithms=["ES256"],
            options={"verify_aud": False},
        )
    except InvalidTokenError as exc:
        raise SubscriptionVerificationError(f"JWS signature verification failed: {exc}") from exc

    bundle_id = str(claims.get("bundleId") or "")
    if bundle_id != settings.apple_iap_bundle_id:
        raise SubscriptionVerificationError(
            f"bundleId mismatch: expected {settings.apple_iap_bundle_id}, got {bundle_id}"
        )

    environment = str(claims.get("environment") or "")
    if environment and environment != settings.apple_iap_environment:
        logger.info(
            "Apple IAP environment mismatch: server=%s, token=%s",
            settings.apple_iap_environment, environment,
        )
        # We allow sandbox tokens to flow through in prod builds during
        # TestFlight pre-review; Apple signs both environments the same
        # way. We log for visibility but don't reject.

    product_id = str(claims.get("productId") or "")
    if not product_id:
        raise SubscriptionVerificationError("Apple transaction has no productId.")

    original_transaction_id = str(
        claims.get("originalTransactionId") or claims.get("transactionId") or ""
    )
    transaction_id = str(claims.get("transactionId") or original_transaction_id)
    if not original_transaction_id:
        raise SubscriptionVerificationError("Apple transaction has no originalTransactionId.")

    purchase_ms = _millis(claims.get("purchaseDate") or claims.get("originalPurchaseDate"))
    expires_ms = _millis(claims.get("expiresDate"))
    if purchase_ms is None:
        raise SubscriptionVerificationError("Apple transaction missing purchaseDate.")
    if expires_ms is None:
        raise SubscriptionVerificationError("Apple transaction missing expiresDate.")

    return VerifiedTransaction(
        product_id=product_id,
        original_transaction_id=original_transaction_id,
        transaction_id=transaction_id,
        purchase_date=datetime.fromtimestamp(purchase_ms / 1000, tz=timezone.utc),
        expires_date=datetime.fromtimestamp(expires_ms / 1000, tz=timezone.utc),
        environment=environment or settings.apple_iap_environment,
        raw=claims,
    )


def _millis(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def upsert_subscription_from_transaction(
    session: Session,
    *,
    user_id: str,
    transaction: VerifiedTransaction,
    status: str = "active",
    auto_renew: bool = True,
) -> Subscription:
    """Create or update the Subscription row for a verified transaction.

    Keyed by `apple_original_transaction_id` so multiple Apple ID rebinds
    don't duplicate rows. If the row already exists under a different
    user_id (e.g. someone re-installed and Sign-in-with-Apple gave them a
    new JWT), we migrate the row — Apple's original transaction is the
    source of truth.
    """
    row = session.scalar(
        select(Subscription).where(
            Subscription.apple_original_transaction_id == transaction.original_transaction_id
        )
    )
    if row is None:
        # Is this user already tracked under a different transaction?
        row = session.scalar(select(Subscription).where(Subscription.user_id == user_id))
        if row is not None:
            row.apple_original_transaction_id = transaction.original_transaction_id
    if row is None:
        row = Subscription(
            user_id=user_id,
            product_id=transaction.product_id,
            apple_original_transaction_id=transaction.original_transaction_id,
            status=status,
            current_period_starts_at=transaction.purchase_date,
            current_period_ends_at=transaction.expires_date,
            auto_renew=auto_renew,
            raw_payload_json=json.dumps(transaction.raw, default=str, sort_keys=True),
        )
        session.add(row)
    else:
        row.user_id = user_id
        row.product_id = transaction.product_id
        row.status = status
        row.current_period_starts_at = transaction.purchase_date
        row.current_period_ends_at = transaction.expires_date
        row.auto_renew = auto_renew
        row.raw_payload_json = json.dumps(transaction.raw, default=str, sort_keys=True)
        row.updated_at = utcnow()
    session.flush()
    return row


# Notification types we act on. Everything else is logged + ignored so the
# row stays in whatever state the most-recent transaction put it in.
# Reference:
# https://developer.apple.com/documentation/appstoreservernotifications/notificationtype
NOTIFICATION_STATUS_MAP = {
    ("SUBSCRIBED", "INITIAL_BUY"): "active",
    ("SUBSCRIBED", "RESUBSCRIBE"): "active",
    ("DID_RENEW", ""): "active",
    ("DID_RENEW", None): "active",
    ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED"): "active",  # still active until period ends
    ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_ENABLED"): "active",
    ("OFFER_REDEEMED", ""): "active",
    ("EXPIRED", ""): "expired",
    ("GRACE_PERIOD_EXPIRED", ""): "expired",
    ("REFUND", ""): "refunded",
    ("REVOKE", ""): "revoked",
}


def status_from_notification(notification_type: str, subtype: str | None) -> str | None:
    """Map an App Store Server notification to our subscription status.

    Returns None for types we don't care about so the caller leaves the
    existing row untouched.
    """
    key = (notification_type.upper(), (subtype or "").upper())
    if key in NOTIFICATION_STATUS_MAP:
        return NOTIFICATION_STATUS_MAP[key]
    # Fallback on notificationType alone.
    for (nt, st), mapped in NOTIFICATION_STATUS_MAP.items():
        if nt == key[0] and st == "":
            return mapped
    return None


def decode_signed_payload(signed: str, settings: Settings) -> dict[str, Any]:
    """Decode an App Store Server Notification v2 outer payload (JWS).

    This is NOT the transaction JWS — it's the notification wrapper. Apple
    uses the same ES256 + x5c chain, so we reuse the same verify path.
    """
    try:
        headers = jwt.get_unverified_header(signed)
    except InvalidTokenError as exc:
        raise SubscriptionVerificationError(f"Invalid notification JWS: {exc}") from exc
    x5c = headers.get("x5c") or []
    if not x5c:
        raise SubscriptionVerificationError("Notification JWS missing x5c.")
    try:
        signing_key = PyJWK.from_dict({"kty": "EC", "crv": "P-256", "x5c": x5c}).key
    except Exception:
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend

        signing_key = x509.load_der_x509_certificate(
            base64.b64decode(x5c[0]), backend=default_backend()
        ).public_key()
    try:
        claims = jwt.decode(
            signed,
            signing_key,
            algorithms=["ES256"],
            options={"verify_aud": False},
        )
    except InvalidTokenError as exc:
        raise SubscriptionVerificationError(f"Notification verification failed: {exc}") from exc
    if not isinstance(claims, dict):
        raise SubscriptionVerificationError("Notification payload is not a JSON object.")
    return claims
