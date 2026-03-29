from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import FileResponse, HTMLResponse

from app.api.assistant import router as assistant_router
from app.api.exports import router as exports_router
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
FRONTEND_DIST_DIR = settings.frontend_dist_dir
FRONTEND_INDEX = FRONTEND_DIST_DIR / 'index.html'


@asynccontextmanager
async def lifespan(_: FastAPI):
    run_migrations()
    with session_scope() as session:
        seed_defaults(session)
    yield


app = FastAPI(title='SimmerSmith', lifespan=lifespan)
protected_dependencies = [Depends(require_api_token)]
app.include_router(assistant_router, dependencies=protected_dependencies)
app.include_router(preferences_router, dependencies=protected_dependencies)
app.include_router(exports_router, dependencies=protected_dependencies)
app.include_router(profile_router, dependencies=protected_dependencies)
app.include_router(recipes_router, dependencies=protected_dependencies)
app.include_router(weeks_router, dependencies=protected_dependencies)


@app.get('/api/health', response_model=HealthResponse)
async def healthcheck() -> HealthResponse:
    with session_scope() as session:
        return HealthResponse(
            status='ok',
            ai_capabilities=await ai_capabilities_payload(settings, profile_settings_map(session)),
        )


def frontend_index_response() -> HTMLResponse | FileResponse:
    if FRONTEND_INDEX.exists():
        return FileResponse(FRONTEND_INDEX)

    return HTMLResponse(
        """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <title>SimmerSmith</title>
          </head>
          <body>
            <main style="font-family: sans-serif; padding: 2rem;">
              <h1>SimmerSmith frontend is not built yet.</h1>
              <p>Run the Vite build or start the dev server to load the new React interface.</p>
            </main>
          </body>
        </html>
        """.strip()
    )


@app.get('/', include_in_schema=False, response_model=None)
def root():
    return frontend_index_response()


@app.get('/{full_path:path}', include_in_schema=False, response_model=None)
def spa_fallback(full_path: str):
    if full_path.startswith('api/'):
        raise HTTPException(status_code=404, detail='Not found')

    requested_path = (FRONTEND_DIST_DIR / full_path).resolve()
    if requested_path.is_file() and FRONTEND_DIST_DIR in requested_path.parents:
        return FileResponse(requested_path)

    return frontend_index_response()
