"""Push notification scheduler (M18).

Runs in-process on the FastAPI app. Two interval jobs fire every
`push_scheduler_tick_seconds` (default 5 min):

  _tick_tonights_meal   — daily, user-local time (default 17:00)
  _tick_saturday_plan   — weekly on Friday, user-local time (default 18:00)

Design decision: single Fly machine, single in-process scheduler.
If the app is ever scaled to 2+ machines, switch to a Postgres advisory
lock or Fly `machines run` cron. Documented in decisions.md.

Idempotency is handled by:
  1. APNs `apns-collapse-id` — prevents double-delivery to the same device.
  2. An in-memory `_sent_today` dict keyed by (user_id, date/week_start) that
     resets on server restart. Acceptable risk: a restart within the same
     minute could double-fire.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Callable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.db import session_scope
from app.models.profile import ProfileSetting
from app.models.push import PushDevice
from app.models.week import Week, WeekMeal
from app.services.push_apns import is_apns_configured, send_push

logger = logging.getLogger(__name__)

# In-memory de-duplication: keyed by (kind, user_id, date_key) → True.
# Cleared on restart — acceptable because collapse_id provides APNs-level
# de-dup and a restart is a rare event.
_sent_today: dict[tuple[str, str, str], bool] = {}


def _effective_toggle(user_settings: dict[str, str], key: str, default: str = "1") -> bool:
    """Return True for enabled toggle.

    An absent row defaults to '1' (on-by-default per spec).
    An explicit '0' is disabled. Everything else is treated as enabled.
    """
    val = user_settings.get(key, default)
    return val != "0"


def _parse_time(time_str: str) -> tuple[int, int] | None:
    """Parse 'HH:MM' → (hour, minute). Returns None on malformed input."""
    try:
        parts = time_str.strip().split(":")
        if len(parts) != 2:
            return None
        return int(parts[0]), int(parts[1])
    except (ValueError, AttributeError):
        return None


def _within_window(
    now_local: datetime,
    target_hour: int,
    target_minute: int,
    tick_seconds: int,
) -> bool:
    """Return True when now_local is within ±tick_seconds/2 of the target time."""
    target = now_local.replace(hour=target_hour, minute=target_minute, second=0, microsecond=0)
    delta = abs((now_local - target).total_seconds())
    return delta <= tick_seconds / 2


def _is_quiet_hours(now_local: datetime) -> bool:
    """Return True when push should be silenced (22:00–07:00 local)."""
    hour = now_local.hour
    return hour >= 22 or hour < 7


def _get_user_settings(session: Session, user_id: str) -> dict[str, str]:
    """Load profile_settings for user_id as a plain dict."""
    rows = session.scalars(
        select(ProfileSetting).where(ProfileSetting.user_id == user_id)
    ).all()
    return {row.key: row.value for row in rows}


def _active_user_ids(session: Session) -> list[str]:
    """Return distinct user_ids that have at least one non-disabled push device."""
    rows = session.scalars(
        select(PushDevice.user_id)
        .where(PushDevice.disabled_at.is_(None))
        .distinct()
    ).all()
    return list(rows)


async def _tick_tonights_meal(
    settings: Settings,
    now_local: Callable[[str], datetime] | None = None,
) -> None:
    """Fire tonight's-meal push for eligible users."""
    with session_scope() as session:
        user_ids = _active_user_ids(session)
        for user_id in user_ids:
            try:
                await _process_tonights_meal(session, settings, user_id, now_local)
            except Exception:
                logger.exception("_tick_tonights_meal: error for user=%s", user_id)


async def _process_tonights_meal(
    session: Session,
    settings: Settings,
    user_id: str,
    now_local_fn: Callable[[str], datetime] | None,
) -> None:
    user_settings = _get_user_settings(session, user_id)
    if not _effective_toggle(user_settings, "push_tonights_meal"):
        return

    tz_name = user_settings.get("timezone") or "America/Chicago"
    try:
        tz = ZoneInfo(tz_name)
    except ZoneInfoNotFoundError:
        tz = ZoneInfo("America/Chicago")

    now = now_local_fn(tz_name) if now_local_fn else datetime.now(tz)

    if _is_quiet_hours(now):
        return

    time_str = user_settings.get("push_tonights_meal_time") or "17:00"
    parsed = _parse_time(time_str)
    if parsed is None:
        logger.warning("_tick_tonights_meal: malformed time '%s' for user=%s", time_str, user_id)
        return

    target_hour, target_minute = parsed
    if not _within_window(now, target_hour, target_minute, settings.push_scheduler_tick_seconds):
        return

    today_local = now.date()
    dedup_key = ("tonights_meal", user_id, today_local.isoformat())
    if _sent_today.get(dedup_key):
        return

    # Find today's primary dinner meal
    meal = session.scalar(
        select(WeekMeal)
        .join(Week, WeekMeal.week_id == Week.id)
        .where(
            Week.user_id == user_id,
            WeekMeal.meal_date == today_local,
            WeekMeal.slot == "dinner",
        )
        .order_by(WeekMeal.sort_order)
        .limit(1)
    )
    if meal is None:
        logger.debug("_tick_tonights_meal: no dinner meal for user=%s today=%s", user_id, today_local)
        return

    recipe_name = meal.recipe_name or "dinner"
    collapse_id = f"tonight-{user_id}-{today_local.isoformat()}"

    delivered = await send_push(
        session,
        settings=settings,
        user_id=user_id,
        title="Tonight's meal",
        body=f"Tonight: {recipe_name}",
        payload={"deep_link": "simmersmith://week"},
        collapse_id=collapse_id,
    )
    if delivered > 0:
        _sent_today[dedup_key] = True
        logger.info("_tick_tonights_meal: delivered=%d user=%s recipe=%s", delivered, user_id, recipe_name)


async def _tick_saturday_plan(
    settings: Settings,
    now_local: Callable[[str], datetime] | None = None,
) -> None:
    """Fire Saturday-plan-reminder push for eligible users."""
    with session_scope() as session:
        user_ids = _active_user_ids(session)
        for user_id in user_ids:
            try:
                await _process_saturday_plan(session, settings, user_id, now_local)
            except Exception:
                logger.exception("_tick_saturday_plan: error for user=%s", user_id)


async def _process_saturday_plan(
    session: Session,
    settings: Settings,
    user_id: str,
    now_local_fn: Callable[[str], datetime] | None,
) -> None:
    user_settings = _get_user_settings(session, user_id)
    if not _effective_toggle(user_settings, "push_saturday_plan"):
        return

    tz_name = user_settings.get("timezone") or "America/Chicago"
    try:
        tz = ZoneInfo(tz_name)
    except ZoneInfoNotFoundError:
        tz = ZoneInfo("America/Chicago")

    now = now_local_fn(tz_name) if now_local_fn else datetime.now(tz)

    if _is_quiet_hours(now):
        return

    # Only fire on Friday (weekday() == 4)
    if now.weekday() != 4:
        return

    time_str = user_settings.get("push_saturday_plan_time") or "18:00"
    parsed = _parse_time(time_str)
    if parsed is None:
        logger.warning("_tick_saturday_plan: malformed time '%s' for user=%s", time_str, user_id)
        return

    target_hour, target_minute = parsed
    if not _within_window(now, target_hour, target_minute, settings.push_scheduler_tick_seconds):
        return

    # Determine the upcoming Monday week_start
    today_local = now.date()
    days_until_monday = (7 - today_local.weekday()) % 7
    if days_until_monday == 0:
        days_until_monday = 7
    upcoming_monday = today_local + timedelta(days=days_until_monday)
    week_start_iso = upcoming_monday.isoformat()

    dedup_key = ("saturday_plan", user_id, week_start_iso)
    if _sent_today.get(dedup_key):
        return

    # Check if the upcoming week exists and has a non-draft status
    upcoming_week = session.scalar(
        select(Week).where(
            Week.user_id == user_id,
            Week.week_start == upcoming_monday,
        )
    )
    if upcoming_week is not None and upcoming_week.status not in ("staging", "draft"):
        # Week is approved/confirmed — skip
        logger.debug(
            "_tick_saturday_plan: upcoming week status=%s for user=%s — skipping",
            upcoming_week.status,
            user_id,
        )
        return

    collapse_id = f"saturday-{user_id}-{week_start_iso}"
    delivered = await send_push(
        session,
        settings=settings,
        user_id=user_id,
        title="Plan your week",
        body="Your upcoming week is still open — plan it now.",
        payload={"deep_link": "simmersmith://assistant?intent=plan_my_week"},
        collapse_id=collapse_id,
    )
    if delivered > 0:
        _sent_today[dedup_key] = True
        logger.info("_tick_saturday_plan: delivered=%d user=%s week=%s", delivered, user_id, week_start_iso)


def start_scheduler(settings: Settings):
    """Start the APScheduler instance.

    Returns None when push_scheduler_enabled is False or APNs is not
    configured — callers should handle None gracefully.
    """
    if not settings.push_scheduler_enabled:
        logger.info("push_scheduler: disabled via push_scheduler_enabled=False")
        return None

    if not is_apns_configured(settings):
        logger.info("push_scheduler: APNs not configured — scheduler will not start")
        return None

    try:
        from apscheduler.schedulers.asyncio import AsyncIOScheduler  # noqa: PLC0415
        from apscheduler.triggers.interval import IntervalTrigger  # noqa: PLC0415
    except ImportError:
        logger.warning("push_scheduler: apscheduler not installed — skipping")
        return None

    scheduler = AsyncIOScheduler()

    async def _tonights_meal_job() -> None:
        await _tick_tonights_meal(settings)

    async def _saturday_plan_job() -> None:
        await _tick_saturday_plan(settings)

    scheduler.add_job(
        _tonights_meal_job,
        trigger=IntervalTrigger(seconds=settings.push_scheduler_tick_seconds),
        id="push_tonights_meal",
        max_instances=1,
        coalesce=True,
    )
    scheduler.add_job(
        _saturday_plan_job,
        trigger=IntervalTrigger(seconds=settings.push_scheduler_tick_seconds),
        id="push_saturday_plan",
        max_instances=1,
        coalesce=True,
    )

    scheduler.start()
    logger.info(
        "push_scheduler: started (tick=%ds)", settings.push_scheduler_tick_seconds
    )
    return scheduler
