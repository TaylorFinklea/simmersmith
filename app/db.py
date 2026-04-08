from __future__ import annotations

import logging
from contextlib import contextmanager
from functools import lru_cache

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import get_settings

logger = logging.getLogger(__name__)


class Base(DeclarativeBase):
    pass


@lru_cache(maxsize=1)
def get_engine():
    settings = get_settings()
    engine_kwargs: dict[str, object] = {}
    if settings.database_url.startswith("sqlite"):
        engine_kwargs["connect_args"] = {"check_same_thread": False}
    return create_engine(
        settings.database_url,
        future=True,
        **engine_kwargs,
    )


@lru_cache(maxsize=1)
def get_session_factory():
    return sessionmaker(
        bind=get_engine(), autoflush=False, autocommit=False, expire_on_commit=False
    )


def reset_db_state() -> None:
    try:
        engine = get_engine()
    except Exception:
        logger.warning("reset_db_state: failed to get engine, skipping dispose")
        engine = None
    if engine is not None:
        engine.dispose()
    get_session_factory.cache_clear()
    get_engine.cache_clear()


def get_session() -> Session:
    session = get_session_factory()()
    try:
        yield session
    finally:
        session.close()


@contextmanager
def session_scope() -> Session:
    session = get_session_factory()()
    try:
        yield session
        session.commit()
    except Exception:
        logger.exception("session_scope: database error, rolling back")
        session.rollback()
        raise
    finally:
        session.close()
