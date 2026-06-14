"""StoreKit 2 subscription endpoints — client verify + App Store webhook."""
from __future__ import annotations

import logging

from fastapi import APIRouter, Body, Depends, HTTPException, Response, status
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings
from app.db import get_session
from app.services.subscriptions import (
    TERMINAL_STATUSES,
    SubscriptionVerificationError,
    app_account_token_conflict,
    decode_signed_payload,
    status_from_notification,
    transaction_is_stale,
    upsert_subscription_from_transaction,
    verify_transaction_jws,
)


def _subscription_out(row) -> dict[str, object]:
    return {
        "status": row.status,
        "product_id": row.product_id,
        "current_period_starts_at": row.current_period_starts_at.isoformat(),
        "current_period_ends_at": row.current_period_ends_at.isoformat(),
        "auto_renew": row.auto_renew,
    }


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/subscriptions", tags=["subscriptions"])


class VerifyTransactionRequest(BaseModel):
    """Body the iOS client sends after a successful StoreKit purchase.

    `signed_transaction` is the JWSTransaction string from
    `Transaction.currentEntitlements` / `Product.purchase()`.
    """
    signed_transaction: str


class SubscriptionOut(BaseModel):
    status: str
    product_id: str
    current_period_starts_at: str
    current_period_ends_at: str
    auto_renew: bool


@router.post("/verify", response_model=SubscriptionOut)
def verify_client_transaction(
    payload: VerifyTransactionRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
) -> dict[str, object]:
    try:
        verified = verify_transaction_jws(payload.signed_transaction, settings)
    except SubscriptionVerificationError as exc:
        logger.warning("Subscription verify rejected for user=%s: %s", current_user.id, exc)
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    from sqlalchemy import select as _select

    from app.models import Subscription

    existing = session.scalar(
        _select(Subscription).where(
            Subscription.apple_original_transaction_id == verified.original_transaction_id
        )
    )
    if existing is not None:
        # Refuse a receipt that's bound (via appAccountToken) to a different
        # account — stops one user claiming another's paid subscription.
        if app_account_token_conflict(existing.app_account_token, verified.app_account_token):
            logger.warning(
                "Subscription verify rejected: appAccountToken mismatch for originalTransactionId=%s",
                verified.original_transaction_id,
            )
            raise HTTPException(status_code=409, detail="This receipt is bound to a different account.")
        # Ownership guard: the row already belongs to another user. Never
        # silently migrate it to the caller on the verify path — that's an
        # account takeover when the iOS client doesn't set appAccountToken
        # (the conflict guard above is inert with both tokens null). Only
        # allow re-binding when the receipt positively binds to the caller
        # via a matching, non-null appAccountToken.
        if existing.user_id != current_user.id and not (
            verified.app_account_token
            and existing.app_account_token
            and verified.app_account_token == existing.app_account_token
        ):
            logger.warning(
                "Subscription verify rejected: originalTransactionId=%s owned by another account",
                verified.original_transaction_id,
            )
            raise HTTPException(status_code=409, detail="This receipt is bound to a different account.")
        # Replaying an older/equal transaction — return the current row
        # unchanged rather than re-applying stale state.
        if transaction_is_stale(verified.transaction_id, existing.last_transaction_id):
            return _subscription_out(existing)

    row = upsert_subscription_from_transaction(
        session,
        user_id=current_user.id,
        transaction=verified,
        status="active",
        auto_renew=True,
    )
    session.commit()
    return _subscription_out(row)


class AppleWebhookPayload(BaseModel):
    """App Store Server Notifications v2 outer envelope."""
    signedPayload: str


@router.post("/apple-webhook", include_in_schema=False)
def apple_webhook(
    payload: AppleWebhookPayload = Body(...),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> Response:
    """Receive Apple's signed server-to-server notifications.

    The handler is intentionally permissive about missing rows — Apple
    sometimes sends notifications for transactions we have not yet seen
    (e.g. when the user signs up via Family Sharing). We still upsert and
    set the status from the notification type. Authentication here is
    purely the JWS signature; no bearer token is required.
    """
    try:
        claims = decode_signed_payload(payload.signedPayload, settings)
    except SubscriptionVerificationError as exc:
        logger.warning("Apple webhook rejected: %s", exc)
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    notification_type = str(claims.get("notificationType") or "")
    subtype = str(claims.get("subtype") or "")
    notification_uuid = str(claims.get("notificationUUID") or "")
    logger.info("Apple webhook: type=%s subtype=%s uuid=%s", notification_type, subtype, notification_uuid)

    from datetime import datetime, timedelta, timezone

    from sqlalchemy import select as _select

    from app.models import ProcessedAppleNotification, Subscription
    from app.models import utcnow as _utcnow

    # (b) Freshness: silently accept-and-drop notifications older than the
    # configured window so a replayed stale delivery can't move state (and
    # Apple stops retrying — 4xx/5xx would just trigger more retries).
    signed_date = claims.get("signedDate")
    max_age = settings.apple_iap_webhook_max_age_days
    if max_age and signed_date:
        try:
            sent_at = datetime.fromtimestamp(int(signed_date) / 1000, tz=timezone.utc)
            if datetime.now(timezone.utc) - sent_at > timedelta(days=max_age):
                logger.info("Apple webhook signedDate %s older than %dd; ignoring", sent_at, max_age)
                return Response(status_code=status.HTTP_204_NO_CONTENT)
        except (TypeError, ValueError, OverflowError, OSError):
            pass

    # (a) Replay dedup: if we've already processed this notificationUUID, drop it.
    if notification_uuid and session.scalar(
        _select(ProcessedAppleNotification).where(
            ProcessedAppleNotification.notification_uuid == notification_uuid
        )
    ):
        logger.info("Apple webhook duplicate notificationUUID=%s; ignoring", notification_uuid)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    data = claims.get("data") or {}
    signed_transaction = (
        (data.get("signedTransactionInfo") if isinstance(data, dict) else None)
        or ""
    )
    if not signed_transaction:
        logger.info("Apple webhook had no transaction info; skipping")
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    try:
        verified = verify_transaction_jws(signed_transaction, settings)
    except SubscriptionVerificationError as exc:
        logger.warning("Apple webhook inner JWS rejected: %s", exc)
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    # The webhook doesn't carry our own user_id — we resolve the row by
    # original transaction id. If we don't have one yet, the first client
    # verify call will create it.
    existing = session.scalar(
        _select(Subscription).where(
            Subscription.apple_original_transaction_id == verified.original_transaction_id
        )
    )
    if existing is None:
        logger.info(
            "Apple webhook for unseen originalTransactionId=%s; deferring until client verify",
            verified.original_transaction_id,
        )
    elif app_account_token_conflict(existing.app_account_token, verified.app_account_token):
        logger.warning(
            "Apple webhook appAccountToken mismatch for originalTransactionId=%s; ignoring",
            verified.original_transaction_id,
        )
    elif transaction_is_stale(verified.transaction_id, existing.last_transaction_id):
        logger.info(
            "Apple webhook stale transactionId=%s (last applied=%s); ignoring",
            verified.transaction_id, existing.last_transaction_id,
        )
    else:
        new_status = status_from_notification(notification_type, subtype)
        if new_status is not None:
            existing.status = new_status
        # (c) Only advance the period window for a recognized ACTIVE/renewal
        # status. Terminal states freeze it; unmapped types (new_status None —
        # PRICE_INCREASE, RENEWAL_EXTENDED, CONSUMPTION_REQUEST, …) must NOT
        # blindly push the entitlement window forward (M25).
        if new_status in TERMINAL_STATUSES:
            existing.cancelled_at = _utcnow()
        elif new_status == "active":
            existing.current_period_starts_at = verified.purchase_date
            existing.current_period_ends_at = verified.expires_date
        if notification_type.upper() == "DID_CHANGE_RENEWAL_STATUS":
            existing.auto_renew = subtype.upper() == "AUTO_RENEW_ENABLED"
        # Only advance last_transaction_id when the notification actually
        # changed state. Unmapped types (new_status None — PRICE_INCREASE,
        # DID_CHANGE_RENEWAL_PREF, …) share the same transactionId as the
        # later EXPIRED/REFUND in the same billing period; bumping it here
        # would make that terminal notification look stale and get dropped,
        # leaving the user Pro after expiry/refund.
        if new_status is not None:
            existing.last_transaction_id = verified.transaction_id
        if verified.app_account_token and not existing.app_account_token:
            existing.app_account_token = verified.app_account_token

    # Record the UUID so this delivery isn't reprocessed (covers every path
    # above — applied, deferred, stale, conflicted). Atomic with any mutation
    # via the single commit below.
    if notification_uuid:
        session.add(
            ProcessedAppleNotification(
                notification_uuid=notification_uuid,
                notification_type=notification_type,
                subtype=subtype,
            )
        )
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
