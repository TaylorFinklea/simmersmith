"""OAuth 2.1 + PKCE endpoints for the remote MCP server.

This module exposes four endpoints under ``/`` (root, not ``/api``)
so Claude.ai's standard MCP-client discovery hits the conventional
well-known path:

- ``GET /.well-known/oauth-authorization-server`` — RFC 8414 metadata
- ``POST /oauth/register``                       — RFC 7591 DCR
- ``GET /oauth/authorize``                       — user-approval HTML page
- ``POST /oauth/authorize/approve``              — user submits the form
- ``POST /oauth/token``                          — code → JWT (PKCE-verified)

V1 user-auth in the authorize page is "paste the SIMMERSMITH_API_TOKEN"
which approves the local admin user. Real Apple/Google web sign-in is
a follow-up (M24.1); the OAuth surface here doesn't change when that
lands — only the authorize page's HTML.
"""
from __future__ import annotations

import hmac
from typing import Annotated

from fastapi import APIRouter, Depends, Form, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.db import get_session
from app.services.oauth import (
    AuthorizeRequestInputs,
    OAuthError,
    TokenExchangeInputs,
    approve_authorize_request,
    authorization_server_metadata,
    create_pending_authorize_request,
    exchange_code_for_token,
    register_client,
    validate_authorize_request,
)


router = APIRouter(tags=["oauth"])


def _public_base_url(request: Request) -> str:
    """The externally-visible origin Claude.ai will see in metadata.

    Honors ``X-Forwarded-Proto`` / ``X-Forwarded-Host`` for behind-Fly
    deployments where Starlette's ``request.base_url`` may report the
    internal scheme.
    """
    forwarded_proto = request.headers.get("x-forwarded-proto", "").split(",")[0].strip()
    forwarded_host = request.headers.get("x-forwarded-host", "").split(",")[0].strip()
    scheme = forwarded_proto or request.url.scheme
    host = forwarded_host or request.headers.get("host", "") or request.url.netloc
    return f"{scheme}://{host}"


def _oauth_error_response(err: OAuthError, status_code: int = 400) -> JSONResponse:
    """Translate ``OAuthError`` into the RFC 6749 token-error JSON
    body. Used by /token; the authorize page uses HTML responses
    instead."""
    return JSONResponse(
        status_code=status_code,
        content={"error": err.code, "error_description": err.description},
    )


# ── 1. Metadata ────────────────────────────────────────────────────


@router.get("/.well-known/oauth-authorization-server")
def oauth_metadata(request: Request) -> dict[str, object]:
    """RFC 8414 metadata Claude.ai fetches on first add-server attempt."""
    return authorization_server_metadata(_public_base_url(request), scopes=["mcp"])


# ── 2. Dynamic Client Registration ─────────────────────────────────


class RegisterRequest(BaseModel):
    client_name: str = Field(default="Unnamed client", max_length=120)
    redirect_uris: list[str] = Field(default_factory=list)
    # The remaining fields in RFC 7591 (grant_types, response_types,
    # scope, token_endpoint_auth_method) are accepted but ignored; our
    # server only supports authorization_code + PKCE for public clients.
    grant_types: list[str] | None = None
    response_types: list[str] | None = None
    scope: str | None = None
    token_endpoint_auth_method: str | None = None


class RegisterResponse(BaseModel):
    client_id: str
    client_name: str
    redirect_uris: list[str]
    grant_types: list[str]
    response_types: list[str]
    token_endpoint_auth_method: str


@router.post("/oauth/register", response_model=RegisterResponse, status_code=status.HTTP_201_CREATED)
def register(
    body: RegisterRequest,
    session: Session = Depends(get_session),
) -> RegisterResponse:
    try:
        client = register_client(
            session,
            client_name=body.client_name,
            redirect_uris=body.redirect_uris,
        )
    except OAuthError as err:
        raise HTTPException(status_code=400, detail={"error": err.code, "error_description": err.description}) from err
    session.commit()
    return RegisterResponse(
        client_id=client.client_id,
        client_name=client.client_name,
        redirect_uris=client.redirect_uris,
        grant_types=["authorization_code"],
        response_types=["code"],
        token_endpoint_auth_method="none",
    )


# ── 3. Authorize endpoint (HTML user-approval page) ───────────────


_AUTHORIZE_PAGE_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Connect to SimmerSmith</title>
  <style>
    :root {{ color-scheme: light dark; }}
    body {{ font-family: -apple-system, system-ui, "Helvetica Neue", sans-serif;
           max-width: 480px; margin: 4rem auto; padding: 0 1.25rem; color: #222; line-height: 1.55; }}
    @media (prefers-color-scheme: dark) {{ body {{ color: #eee; background: #1a1714; }} }}
    h1 {{ font-style: italic; font-weight: 600; font-size: 1.5rem; margin: 0 0 .25rem; }}
    .accent {{ color: #E8541C; }}
    .client {{ background: rgba(232,84,28,.08); border: 1px solid rgba(232,84,28,.3);
              padding: .65rem .9rem; border-radius: 6px; margin: 1.5rem 0; font-size: .95rem; }}
    label {{ display: block; font-size: .85rem; opacity: .75; margin: 1.25rem 0 .35rem; }}
    input[type=password] {{ width: 100%; padding: .55rem .75rem; font-size: 1rem;
                            border: 1px solid rgba(0,0,0,.2); border-radius: 4px;
                            background: rgba(0,0,0,.02); box-sizing: border-box; }}
    @media (prefers-color-scheme: dark) {{ input[type=password] {{ background: rgba(255,255,255,.05); border-color: rgba(255,255,255,.15); color: #eee; }} }}
    button {{ background: #E8541C; color: white; border: 0; padding: .65rem 1.25rem;
             border-radius: 4px; font-size: 1rem; font-weight: 500; cursor: pointer;
             margin-top: 1rem; }}
    button:hover {{ background: #d44915; }}
    .deny {{ background: transparent; color: inherit; border: 1px solid rgba(0,0,0,.2); margin-left: .5rem; }}
    @media (prefers-color-scheme: dark) {{ .deny {{ border-color: rgba(255,255,255,.2); }} }}
    .error {{ background: rgba(220,53,69,.1); border: 1px solid rgba(220,53,69,.3);
             color: #b02a37; padding: .55rem .85rem; border-radius: 4px; margin: 1rem 0; font-size: .9rem; }}
    .hint {{ font-size: .82rem; opacity: .6; margin-top: .35rem; }}
  </style>
</head>
<body>
  <h1>simmer<span class="accent">·</span>smith</h1>
  <p>Sign in to connect SimmerSmith to <strong>{client_name}</strong>.</p>
  <div class="client">
    <strong>{client_name}</strong> will be able to view and modify your meal plans, recipes, and shopping lists.
  </div>
  {error_html}
  <form method="post" action="/oauth/authorize/approve">
    <input type="hidden" name="code" value="{code}">
    <label for="api_token">SimmerSmith API token</label>
    <input id="api_token" name="api_token" type="password" autocomplete="off" required>
    <div class="hint">During the beta, paste your SIMMERSMITH_API_TOKEN here. Web sign-in (Apple / Google) lands in a follow-up build.</div>
    <button type="submit">Allow</button>
    <a href="{deny_redirect}"><button type="button" class="deny">Deny</button></a>
  </form>
</body>
</html>"""


def _render_authorize_page(*, code: str, client_name: str, deny_redirect: str, error: str = "") -> HTMLResponse:
    error_html = f'<div class="error">{error}</div>' if error else ""
    html = _AUTHORIZE_PAGE_TEMPLATE.format(
        code=code,
        client_name=client_name,
        deny_redirect=deny_redirect,
        error_html=error_html,
    )
    return HTMLResponse(html)


@router.get("/oauth/authorize")
def oauth_authorize(
    response_type: str,
    client_id: str,
    redirect_uri: str,
    code_challenge: str,
    code_challenge_method: str = "S256",
    state: str | None = None,
    scope: str | None = None,
    session: Session = Depends(get_session),
) -> HTMLResponse:
    """User-facing authorize endpoint.

    Validates the inbound query, persists the pending PKCE state, and
    renders an HTML approval page. On valid form submission the approve
    endpoint redirects to ``redirect_uri`` with the authorization code.
    """
    if response_type != "code":
        raise HTTPException(
            status_code=400,
            detail={"error": "unsupported_response_type",
                    "error_description": "Only response_type=code is supported."},
        )
    try:
        client = validate_authorize_request(
            session,
            AuthorizeRequestInputs(
                client_id=client_id,
                redirect_uri=redirect_uri,
                code_challenge=code_challenge,
                code_challenge_method=code_challenge_method,
                state=state,
                scope=scope,
            ),
        )
        pending = create_pending_authorize_request(
            session,
            client=client,
            inputs=AuthorizeRequestInputs(
                client_id=client_id,
                redirect_uri=redirect_uri,
                code_challenge=code_challenge,
                code_challenge_method=code_challenge_method,
                state=state,
                scope=scope,
            ),
        )
    except OAuthError as err:
        raise HTTPException(
            status_code=400,
            detail={"error": err.code, "error_description": err.description},
        ) from err

    session.commit()
    deny_redirect = _build_deny_redirect(redirect_uri, state)
    return _render_authorize_page(
        code=pending.code,
        client_name=client.client_name,
        deny_redirect=deny_redirect,
    )


def _build_deny_redirect(redirect_uri: str, state: str | None) -> str:
    sep = "&" if "?" in redirect_uri else "?"
    params = ["error=access_denied", "error_description=User+denied+access"]
    if state:
        params.append(f"state={state}")
    return f"{redirect_uri}{sep}{'&'.join(params)}"


@router.post("/oauth/authorize/approve", include_in_schema=False, response_model=None)
def oauth_authorize_approve(
    code: Annotated[str, Form()],
    api_token: Annotated[str, Form()],
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> HTMLResponse | RedirectResponse:
    """Handles the authorize page's form submission.

    V1 user-auth: validates ``api_token`` against ``settings.api_token``
    and approves the pending request for ``settings.local_user_id``.
    M24.1 will swap this in for real Apple/Google web sign-in.
    """
    pending = session.scalar(
        __pending_query(code)
    )
    if pending is None:
        raise HTTPException(status_code=404, detail="Unknown authorization request.")

    # V1 user-auth: compare bearer to the configured admin token.
    expected = (settings.api_token or "").strip()
    if not expected:
        return _render_authorize_page(
            code=code,
            client_name=_lookup_client_name(session, pending.client_id),
            deny_redirect=_build_deny_redirect(pending.redirect_uri, pending.state),
            error="Server has no SIMMERSMITH_API_TOKEN configured; cannot authorize.",
        )
    if not hmac.compare_digest(api_token.strip(), expected):
        return _render_authorize_page(
            code=code,
            client_name=_lookup_client_name(session, pending.client_id),
            deny_redirect=_build_deny_redirect(pending.redirect_uri, pending.state),
            error="That token didn't match. Try again.",
        )

    try:
        approve_authorize_request(
            session,
            code=code,
            user_id=settings.local_user_id,
        )
    except OAuthError as err:
        raise HTTPException(
            status_code=400,
            detail={"error": err.code, "error_description": err.description},
        ) from err

    session.commit()
    sep = "&" if "?" in pending.redirect_uri else "?"
    params = [f"code={pending.code}"]
    if pending.state:
        params.append(f"state={pending.state}")
    return RedirectResponse(
        url=f"{pending.redirect_uri}{sep}{'&'.join(params)}",
        status_code=302,
    )


def __pending_query(code: str):
    """Imported lazily so test patches of `select` don't trip module load."""
    from sqlalchemy import select

    from app.models import OAuthAuthorizeRequest as _Req

    return select(_Req).where(_Req.code == code)


def _lookup_client_name(session: Session, client_id: str) -> str:
    from app.services.oauth import get_client

    client = get_client(session, client_id)
    return client.client_name if client else "an external client"


# ── 4. Token endpoint ─────────────────────────────────────────────


@router.post("/oauth/token")
def oauth_token(
    grant_type: Annotated[str, Form()],
    code: Annotated[str, Form()],
    client_id: Annotated[str, Form()],
    redirect_uri: Annotated[str, Form()],
    code_verifier: Annotated[str, Form()],
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> JSONResponse:
    try:
        grant = exchange_code_for_token(
            session,
            settings,
            TokenExchangeInputs(
                grant_type=grant_type,
                code=code,
                client_id=client_id,
                redirect_uri=redirect_uri,
                code_verifier=code_verifier,
            ),
        )
    except OAuthError as err:
        return _oauth_error_response(err)
    session.commit()
    body: dict[str, object] = {
        "access_token": grant.access_token,
        "token_type": grant.token_type,
        "expires_in": grant.expires_in,
    }
    if grant.scope:
        body["scope"] = grant.scope
    return JSONResponse(body)
