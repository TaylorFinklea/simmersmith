from __future__ import annotations

from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.models import ProfileSetting, Staple, utcnow
from app.services.ingredient_catalog import ensure_catalog_defaults
from app.services.recipe_templates import ensure_default_templates
from app.services.nutrition import ensure_ingredient_macros_seed, ensure_nutrition_defaults


DEFAULT_PROFILE_SETTINGS = {
    "household_name": "",
    "household_adults": "",
    "household_kids": "",
    "week_start_day": "Monday",
    "default_slots": "breakfast,lunch,dinner,snack",
    "dietary_constraints": "",
    "cuisine_preferences": "",
    "budget_notes": "",
    "monthly_grocery_budget_usd": "",
    "food_principles": "",
    "convenience_rules": "",
    "breakfast_strategy": "",
    "lunch_strategy": "",
    "snack_strategy": "",
    "leftovers_policy": "",
    "portable_lunch_days": "",
    "brand_preferences": "",
    "planning_avoids": "",
    "saturday_dinner_plan": "",
    "timezone": "America/Chicago",
    "currency": "USD",
    "aldi_store_name": "",
    "aldi_store_zip": "",
    "aldi_store_id": "",
    "walmart_store_name": "",
    "walmart_store_zip": "",
    "walmart_store_id": "",
    "ai_provider_mode": "auto",
    "ai_direct_provider": "",
    # Push notification defaults (M18). All on by default.
    "push_tonights_meal": "1",
    "push_saturday_plan": "1",
    "push_tonights_meal_time": "17:00",
    "push_saturday_plan_time": "18:00",
    # M20: AI-finished-thinking push fires after a planning turn that
    # ran tools (typically `generate_week_plan`). iOS suppresses
    # foreground banners automatically, so this is only visible when
    # the user has the app backgrounded.
    "push_assistant_done": "1",
}

DEFAULT_STAPLES = [
    {"staple_name": "Olive oil", "normalized_name": "olive oil", "notes": "", "is_active": True},
    {"staple_name": "Kosher salt", "normalized_name": "kosher salt", "notes": "", "is_active": True},
    {"staple_name": "Black pepper", "normalized_name": "black pepper", "notes": "", "is_active": True},
]


def run_migrations() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    config = Config(str(repo_root / "alembic.ini"))
    config.set_main_option("script_location", str(repo_root / "alembic"))
    config.set_main_option("sqlalchemy.url", get_settings().database_url)
    command.upgrade(config, "head")


def seed_defaults(session: Session) -> None:
    local_user_id = get_settings().local_user_id

    # Ensure the dev/local user has a household before any user-scoped
    # row gets created (Staples below need household_id).
    from app.services.households import (  # noqa: PLC0415
        create_solo_household,
        get_household_id_or_none,
    )
    household_id = get_household_id_or_none(session, local_user_id)
    if household_id is None:
        household_id = create_solo_household(session, local_user_id)

    existing_keys = set(session.scalars(select(ProfileSetting.key)).all())
    for key, value in DEFAULT_PROFILE_SETTINGS.items():
        if key in existing_keys:
            continue
        session.add(ProfileSetting(user_id=local_user_id, key=key, value=value, updated_at=utcnow()))

    existing_staple = session.scalar(select(Staple).limit(1))
    if existing_staple is None:
        for staple in DEFAULT_STAPLES:
            session.add(Staple(user_id=local_user_id, household_id=household_id, **staple))

    ensure_default_templates(session)
    ensure_nutrition_defaults(session)
    ensure_catalog_defaults(session)
    ensure_ingredient_macros_seed(session)
    session.flush()
