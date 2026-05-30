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

import json
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

import attr
from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier, VerificationException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import Subscription, utcnow

# Apple root CAs (DER) the StoreKit JWS chain must terminate at. Bundled in
# the repo because the verifier validates *against* roots the caller supplies.
_APPLE_ROOT_DIR = Path(__file__).resolve().parents[1] / "data" / "apple_roots"


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


@lru_cache(maxsize=1)
def _apple_root_certificates() -> tuple[bytes, ...]:
    """Load the bundled Apple root CA certs (DER) the JWS chain must root in."""
    certs = tuple(p.read_bytes() for p in sorted(_APPLE_ROOT_DIR.glob("*.cer")))
    if not certs:
        raise SubscriptionVerificationError(
            f"No Apple root certificates bundled under {_APPLE_ROOT_DIR}."
        )
    return certs


def _environment_for(name: str) -> Environment:
    return Environment.PRODUCTION if name.strip().lower() == "production" else Environment.SANDBOX


def _build_verifier(environment: Environment, settings: Settings) -> SignedDataVerifier | None:
    """Construct a chain-validating verifier for one environment.

    Production requires the numeric app Apple ID; return None when it isn't
    configured so the caller can skip it rather than crash.
    """
    if environment == Environment.PRODUCTION and settings.apple_iap_app_apple_id is None:
        return None
    return SignedDataVerifier(
        root_certificates=list(_apple_root_certificates()),
        enable_online_checks=False,
        environment=environment,
        bundle_id=settings.apple_iap_bundle_id,
        app_apple_id=settings.apple_iap_app_apple_id,
    )


def _verifiers_in_order(settings: Settings) -> list[SignedDataVerifier]:
    """Verifiers to try, configured environment first then the other.

    Apple signs Sandbox and Production identically, so a TestFlight Sandbox
    receipt should still verify against a Production-configured server — we
    just retry with the other environment on an INVALID_ENVIRONMENT mismatch.
    The chain is fully validated for whichever environment matches.
    """
    primary = _environment_for(settings.apple_iap_environment)
    other = Environment.SANDBOX if primary == Environment.PRODUCTION else Environment.PRODUCTION
    return [v for v in (_build_verifier(primary, settings), _build_verifier(other, settings)) if v is not None]


def _require_verifiers(settings: Settings) -> list[SignedDataVerifier]:
    if not settings.apple_iap_bundle_id:
        raise SubscriptionVerificationError(
            "App Store IAP not configured — set SIMMERSMITH_APPLE_IAP_BUNDLE_ID."
        )
    verifiers = _verifiers_in_order(settings)
    if not verifiers:
        raise SubscriptionVerificationError(
            "Production IAP verification requires SIMMERSMITH_APPLE_IAP_APP_APPLE_ID."
        )
    return verifiers


def verify_transaction_jws(signed: str, settings: Settings) -> VerifiedTransaction:
    """Verify an Apple-signed ``JWSTransaction`` and return the decoded fields.

    Uses Apple's App Store Server Library, which validates the FULL x5c
    certificate chain against the bundled Apple Root CA - G3 (not merely the
    attacker-supplied leaf key in the token header) and checks the bundle id
    and environment. This closes the forgery hole where any self-signed key
    in ``x5c`` was trusted.
    """
    verifiers = _require_verifiers(settings)
    decoded = None
    last_error: Exception | None = None
    for verifier in verifiers:
        try:
            decoded = verifier.verify_and_decode_signed_transaction(signed)
            break
        except VerificationException as exc:
            last_error = exc
    if decoded is None:
        raise SubscriptionVerificationError(f"JWS verification failed: {last_error}") from last_error

    product_id = decoded.productId or ""
    if not product_id:
        raise SubscriptionVerificationError("Apple transaction has no productId.")
    original_transaction_id = decoded.originalTransactionId or decoded.transactionId or ""
    if not original_transaction_id:
        raise SubscriptionVerificationError("Apple transaction has no originalTransactionId.")
    transaction_id = decoded.transactionId or original_transaction_id
    if decoded.purchaseDate is None:
        raise SubscriptionVerificationError("Apple transaction missing purchaseDate.")
    if decoded.expiresDate is None:
        raise SubscriptionVerificationError("Apple transaction missing expiresDate.")

    return VerifiedTransaction(
        product_id=product_id,
        original_transaction_id=original_transaction_id,
        transaction_id=transaction_id,
        purchase_date=datetime.fromtimestamp(decoded.purchaseDate / 1000, tz=timezone.utc),
        expires_date=datetime.fromtimestamp(decoded.expiresDate / 1000, tz=timezone.utc),
        environment=decoded.rawEnvironment or settings.apple_iap_environment,
        raw=attr.asdict(decoded),
    )


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
    """Verify + decode an App Store Server Notification v2 outer payload (JWS).

    Chain-validated via the same App Store Server Library path as the
    transaction JWS. Returns a dict shaped like the raw notification claims
    the webhook handler consumes (notificationType / subtype /
    notificationUUID / signedDate / data.signedTransactionInfo), where the
    inner transaction JWS is verified separately by ``verify_transaction_jws``.
    """
    verifiers = _require_verifiers(settings)
    decoded = None
    last_error: Exception | None = None
    for verifier in verifiers:
        try:
            decoded = verifier.verify_and_decode_notification(signed)
            break
        except VerificationException as exc:
            last_error = exc
    if decoded is None:
        raise SubscriptionVerificationError(
            f"Notification verification failed: {last_error}"
        ) from last_error

    data = getattr(decoded, "data", None)
    signed_tx = getattr(data, "signedTransactionInfo", None) if data is not None else None
    return {
        "notificationType": decoded.rawNotificationType or "",
        "subtype": decoded.rawSubtype or "",
        "notificationUUID": decoded.notificationUUID or "",
        "signedDate": getattr(decoded, "signedDate", None),
        "data": {"signedTransactionInfo": signed_tx} if signed_tx else {},
    }
