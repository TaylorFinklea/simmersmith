"""Auth routes: Apple/Google sign-in token exchange + session info."""
from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import (
    CurrentUser,
    get_current_user,
    issue_session_jwt,
    verify_apple_identity_token,
    verify_google_identity_token,
)
from app.config import Settings, get_settings
from app.db import get_session
from app.models.user import User
from app.models._base import utcnow

router = APIRouter(prefix="/api/auth", tags=["auth"])


class TokenExchangeRequest(BaseModel):
    identity_token: str


class TokenExchangeResponse(BaseModel):
    token: str
    user_id: str
    email: str
    display_name: str
    is_new_user: bool


class MeResponse(BaseModel):
    user_id: str
    email: str
    display_name: str


@router.post("/apple", response_model=TokenExchangeResponse)
def auth_apple(
    body: TokenExchangeRequest,
    settings: Settings = Depends(get_settings),
    session: Session = Depends(get_session),
) -> TokenExchangeResponse:
    claims = verify_apple_identity_token(body.identity_token, settings)
    apple_sub = claims["sub"]
    email = claims.get("email", "")

    user = session.scalars(select(User).where(User.apple_sub == apple_sub)).one_or_none()
    is_new = user is None
    if user is None:
        user = User(apple_sub=apple_sub, email=email, created_at=utcnow())
        session.add(user)
        session.flush()

    token = issue_session_jwt(user.id, settings)
    return TokenExchangeResponse(
        token=token,
        user_id=user.id,
        email=user.email,
        display_name=user.display_name,
        is_new_user=is_new,
    )


@router.post("/google", response_model=TokenExchangeResponse)
def auth_google(
    body: TokenExchangeRequest,
    settings: Settings = Depends(get_settings),
    session: Session = Depends(get_session),
) -> TokenExchangeResponse:
    claims = verify_google_identity_token(body.identity_token, settings)
    google_sub = claims["sub"]
    email = claims.get("email", "")
    name = claims.get("name", "")

    user = session.scalars(select(User).where(User.google_sub == google_sub)).one_or_none()
    is_new = user is None
    if user is None:
        user = User(google_sub=google_sub, email=email, display_name=name, created_at=utcnow())
        session.add(user)
        session.flush()

    token = issue_session_jwt(user.id, settings)
    return TokenExchangeResponse(
        token=token,
        user_id=user.id,
        email=user.email,
        display_name=user.display_name,
        is_new_user=is_new,
    )


@router.get("/me", response_model=MeResponse)
def auth_me(current_user: CurrentUser = Depends(get_current_user)) -> MeResponse:
    return MeResponse(
        user_id=current_user.id,
        email="",
        display_name="",
    )
