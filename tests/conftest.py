from __future__ import annotations
# ruff: noqa: E402

import os
import shutil
import sys
import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


ROOT = Path(__file__).resolve().parents[1]
TEST_DATA_DIR = Path(tempfile.mkdtemp(prefix="simmersmith-tests-"))
TEST_DB_PATH = TEST_DATA_DIR / "meals.db"
os.environ["SIMMERSMITH_DATABASE_URL"] = f"sqlite:///{TEST_DB_PATH}"
os.environ["SIMMERSMITH_STORAGE_SECRET"] = "test-secret"
# Disable the push scheduler so APScheduler does not spawn during pytest
os.environ["SIMMERSMITH_PUSH_SCHEDULER_ENABLED"] = "false"

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.auth import CurrentUser
from app.config import Settings, get_settings
from app.db import reset_db_state, session_scope
from app.main import app
from app.models import User
from app.models._base import new_id
from app.services.bootstrap import run_migrations, seed_defaults


@pytest.fixture(autouse=True)
def reset_database() -> None:
    get_settings.cache_clear()
    reset_db_state()
    db_path = TEST_DB_PATH
    if db_path.exists():
        db_path.unlink()
    run_migrations()
    with session_scope() as session:
        seed_defaults(session)
    yield
    reset_db_state()
    if db_path.exists():
        db_path.unlink()


@pytest.fixture(scope="session", autouse=True)
def cleanup_test_dir() -> None:
    yield
    shutil.rmtree(TEST_DATA_DIR, ignore_errors=True)


@pytest.fixture
def client() -> TestClient:
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def db_session():
    """Return the database session for direct database access in tests."""
    with session_scope() as session:
        yield session


@pytest.fixture
def current_user(db_session) -> CurrentUser:
    """Create and return a test user."""
    user = User(id=new_id(), email="test@example.com")
    db_session.add(user)
    db_session.commit()
    return CurrentUser(id=user.id)


@pytest.fixture
def settings_with_api_token(monkeypatch) -> Settings:
    """Return settings with SIMMERSMITH_API_TOKEN set for admin endpoint testing."""
    monkeypatch.setenv("SIMMERSMITH_API_TOKEN", "test-admin-token")
    get_settings.cache_clear()
    return get_settings()
