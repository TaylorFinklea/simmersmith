from __future__ import annotations

import logging
import sys
import traceback
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI

from app.api.admin import router as admin_router
from app.api.ai import router as ai_router
from app.api.aliases import router as aliases_router
from app.api.assistant import router as assistant_router
from app.api.auth import router as auth_router
from app.api.discovery import router as discovery_router
from app.api.events import events_router, guests_router
from app.api.exports import router as exports_router
from app.api.household import router as household_router
from app.api.oauth import router as oauth_router
from app.api.ingredients import preferences_router as ingredient_preferences_router
from app.api.ingredients import router as ingredients_router
from app.api.pantry import router as pantry_router
from app.api.preferences import router as preferences_router
from app.api.products import router as products_router
from app.api.profile import router as profile_router
from app.api.push import router as push_router
from app.api.recipe_images import router as recipe_images_router
from app.api.recipe_memories import router as recipe_memories_router
from app.api.recipes import router as recipes_router
from app.api.stores import router as stores_router
from app.api.subscriptions import router as subscriptions_router
from app.api.vision import router as vision_router
from app.api.weeks import router as weeks_router
from app.auth import get_current_user
from app.config import get_settings
from app.db import session_scope
from app.schemas import HealthResponse
from app.services.bootstrap import run_migrations, seed_defaults
from app.services.push_scheduler import start_scheduler


logger = logging.getLogger(__name__)

settings = get_settings()


def _log_lifespan_failure(stage: str, exc: BaseException) -> None:
    """Print a startup failure to both stdout and stderr with explicit
    flush so Fly's log tail captures the traceback before the process
    exits. Without this, uvicorn-mediated lifespan exceptions can be
    eaten by output buffering on container teardown — leaving the
    operator with `Main child exited normally with code: 3` and zero
    diagnostic context."""
    banner = f"!!! lifespan failure in {stage} !!!"
    tb = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
    print(banner, flush=True)
    print(tb, flush=True)
    print(banner, file=sys.stderr, flush=True)
    print(tb, file=sys.stderr, flush=True)


@asynccontextmanager
async def lifespan(_: FastAPI):
    try:
        run_migrations()
    except BaseException as exc:
        _log_lifespan_failure("run_migrations", exc)
        raise
    try:
        with session_scope() as session:
            seed_defaults(session)
    except BaseException as exc:
        _log_lifespan_failure("seed_defaults", exc)
        raise
    if not settings.jwt_secret and not settings.api_token.strip():
        logger.warning(
            "No authentication configured — API is open. Set SIMMERSMITH_JWT_SECRET "
            "(production) or SIMMERSMITH_API_TOKEN (dev) before exposing to a network."
        )
    scheduler = start_scheduler(settings) if settings.push_scheduler_enabled else None
    yield
    if scheduler is not None:
        scheduler.shutdown(wait=False)


app = FastAPI(title="SimmerSmith", lifespan=lifespan)
app.include_router(admin_router)  # Public — admin routes handle their own auth
app.include_router(auth_router)  # Public — handles its own auth
app.include_router(oauth_router)  # Public — OAuth metadata + flow; mounted at root
protected_dependencies = [Depends(get_current_user)]
app.include_router(ai_router, dependencies=protected_dependencies)
app.include_router(aliases_router, dependencies=protected_dependencies)
app.include_router(assistant_router, dependencies=protected_dependencies)
app.include_router(discovery_router, dependencies=protected_dependencies)
app.include_router(events_router, dependencies=protected_dependencies)
app.include_router(guests_router, dependencies=protected_dependencies)
app.include_router(household_router, dependencies=protected_dependencies)
app.include_router(preferences_router, dependencies=protected_dependencies)
app.include_router(exports_router, dependencies=protected_dependencies)
app.include_router(ingredients_router, dependencies=protected_dependencies)
app.include_router(ingredient_preferences_router, dependencies=protected_dependencies)
app.include_router(pantry_router, dependencies=protected_dependencies)
app.include_router(products_router, dependencies=protected_dependencies)
app.include_router(profile_router, dependencies=protected_dependencies)
app.include_router(push_router, dependencies=protected_dependencies)
app.include_router(recipe_images_router, dependencies=protected_dependencies)
app.include_router(recipe_memories_router, dependencies=protected_dependencies)
app.include_router(recipes_router, dependencies=protected_dependencies)
app.include_router(vision_router, dependencies=protected_dependencies)
app.include_router(weeks_router, dependencies=protected_dependencies)
app.include_router(stores_router, dependencies=protected_dependencies)
# Subscriptions: /verify requires auth (registered as protected below);
# /apple-webhook must accept Apple's signed request without a bearer token
# so we register it as a public router. Inside the router the webhook route
# authenticates via the JWS signature only.
app.include_router(subscriptions_router)


# Mount the remote MCP endpoint at /mcp.
# - Bearer auth via OAuth-issued JWTs (`app/mcp/auth.py`).
# - User scoping via `_current_user_id_var` ContextVar set by the verifier.
# - Stdio MCP (`scripts/run_simmersmith_mcp.py`) is unaffected.
from app.mcp import build_http_app as _build_mcp_http_app  # noqa: E402

app.mount("/mcp", _build_mcp_http_app())


@app.get("/api/health", response_model=HealthResponse)
async def healthcheck() -> HealthResponse:
    return HealthResponse(status="ok")


# Public SSE diagnostic — emits 20 deltas spaced 100ms apart so we can curl
# this route to prove the server + fly-proxy transport streams incrementally
# independently of OpenAI and any iOS client behavior.
@app.get("/api/assistant/_streamtest")
async def stream_test():
    from app.api.assistant import stream_test_response
    return await stream_test_response()


@app.get("/privacy", include_in_schema=False)
async def privacy_policy():
    from fastapi.responses import HTMLResponse
    return HTMLResponse("""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SimmerSmith Privacy Policy</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:680px;margin:2rem auto;padding:0 1rem;color:#333;line-height:1.6}h1{font-size:1.5rem}h2{font-size:1.1rem;margin-top:2rem}p{margin:0.5rem 0}</style>
</head><body>
<h1>SimmerSmith Privacy Policy</h1>
<p><em>Last updated: April 13, 2026</em></p>

<h2>What We Collect</h2>
<p>SimmerSmith collects the minimum data needed to provide the service:</p>
<ul>
<li><strong>Account info</strong>: Your Apple or Google account identifier and email (used for sign-in only).</li>
<li><strong>Meal plans & recipes</strong>: The meals, recipes, grocery lists, and preferences you create in the app.</li>
<li><strong>Usage data</strong>: Basic request logs for debugging (no analytics tracking).</li>
</ul>

<h2>How We Use It</h2>
<p>Your data is used to provide the SimmerSmith service — meal planning, recipe management, and grocery lists. We send your meal preferences to AI providers (OpenAI) to generate meal plans. We do not sell or share your data with third parties for advertising.</p>

<h2>AI Processing</h2>
<p>When you use AI features (meal planning, recipe suggestions), your preferences and prompts are sent to OpenAI's API for processing. OpenAI's data handling is governed by their privacy policy. We do not send personal information beyond what's needed for meal planning.</p>

<h2>Data Storage</h2>
<p>Your data is stored on servers hosted by Fly.io (US). Data is encrypted in transit (HTTPS) and at rest.</p>

<h2>Your Rights</h2>
<p>You can delete your account and all associated data by contacting us. You can export your recipes and meal plans at any time through the app.</p>

<h2>Contact</h2>
<p>Questions? Email <a href="mailto:privacy@simmersmith.app">privacy@simmersmith.app</a>.</p>
</body></html>""")
