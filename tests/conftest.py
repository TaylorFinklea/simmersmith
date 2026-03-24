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
os.environ["SIMMERSMITH_DATA_DIR"] = str(TEST_DATA_DIR)
os.environ["SIMMERSMITH_DB_PATH"] = str(TEST_DATA_DIR / "meals.db")
os.environ["SIMMERSMITH_STORAGE_SECRET"] = "test-secret"

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.config import get_settings
from app.db import reset_db_state, session_scope
from app.main import app
from app.services.bootstrap import run_migrations, seed_defaults


@pytest.fixture(autouse=True)
def reset_database() -> None:
    get_settings.cache_clear()
    reset_db_state()
    db_path = Path(os.environ["SIMMERSMITH_DB_PATH"])
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
