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
    SubscriptionVerificationError,
    decode_signed_payload,
    status_from_notification,
    upsert_subscription_from_transaction,
    verify_transaction_jws,
)


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

    row = upsert_subscription_from_transaction(
        session,
        user_id=current_user.id,
        transaction=verified,
        status="active",
        auto_renew=True,
    )
    session.commit()
    return {
        "status": row.status,
        "product_id": row.product_id,
        "current_period_starts_at": row.current_period_starts_at.isoformat(),
        "current_period_ends_at": row.current_period_ends_at.isoformat(),
        "auto_renew": row.auto_renew,
    }


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
    logger.info("Apple webhook: type=%s subtype=%s", notification_type, subtype)

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
    from sqlalchemy import select as _select

    from app.models import Subscription

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
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    new_status = status_from_notification(notification_type, subtype)
    if new_status is not None:
        existing.status = new_status
    # Expiry / period timestamps come from the transaction payload; update
    # regardless of status so renewals extend the window.
    existing.current_period_starts_at = verified.purchase_date
    existing.current_period_ends_at = verified.expires_date
    if notification_type.upper() in {"DID_CHANGE_RENEWAL_STATUS"}:
        existing.auto_renew = subtype.upper() == "AUTO_RENEW_ENABLED"
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
