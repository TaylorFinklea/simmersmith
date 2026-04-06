from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI

from app.api.ai import router as ai_router
from app.api.assistant import router as assistant_router
from app.api.exports import router as exports_router
from app.api.ingredients import preferences_router as ingredient_preferences_router
from app.api.ingredients import router as ingredients_router
from app.api.preferences import router as preferences_router
from app.api.profile import router as profile_router
from app.api.recipes import router as recipes_router
from app.api.weeks import router as weeks_router
from app.auth import require_api_token
from app.config import get_settings
from app.db import session_scope
from app.schemas import HealthResponse
from app.services.ai import ai_capabilities_payload, profile_settings_map
from app.services.bootstrap import run_migrations, seed_defaults


settings = get_settings()


@asynccontextmanager
async def lifespan(_: FastAPI):
    run_migrations()
    with session_scope() as session:
        seed_defaults(session)
    yield


app = FastAPI(title="SimmerSmith", lifespan=lifespan)
protected_dependencies = [Depends(require_api_token)]
app.include_router(ai_router, dependencies=protected_dependencies)
app.include_router(assistant_router, dependencies=protected_dependencies)
app.include_router(preferences_router, dependencies=protected_dependencies)
app.include_router(exports_router, dependencies=protected_dependencies)
app.include_router(ingredients_router, dependencies=protected_dependencies)
app.include_router(ingredient_preferences_router, dependencies=protected_dependencies)
app.include_router(profile_router, dependencies=protected_dependencies)
app.include_router(recipes_router, dependencies=protected_dependencies)
app.include_router(weeks_router, dependencies=protected_dependencies)


@app.get("/api/health", response_model=HealthResponse)
async def healthcheck() -> HealthResponse:
    with session_scope() as session:
        return HealthResponse(
            status="ok",
            ai_capabilities=await ai_capabilities_payload(settings, profile_settings_map(session)),
        )
