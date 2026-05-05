"""M27 — unit-system localization (US customary vs metric).

The directive injected into recipe-producing AI prompts. Smoke-tests
the helper + verifies the directive lands in the prompt strings of
the high-traffic AI surfaces.
"""
from __future__ import annotations

from datetime import date

from app.services.ai import unit_system, unit_system_directive
from app.services.bootstrap import DEFAULT_PROFILE_SETTINGS


def test_default_profile_setting_is_us_customary() -> None:
    assert DEFAULT_PROFILE_SETTINGS["unit_system"] == "us"


def test_unit_system_normalizes_to_us_or_metric() -> None:
    assert unit_system({}) == "us"
    assert unit_system({"unit_system": ""}) == "us"
    assert unit_system({"unit_system": "  US  "}) == "us"
    assert unit_system({"unit_system": "Metric"}) == "metric"
    assert unit_system({"unit_system": "metric"}) == "metric"
    assert unit_system({"unit_system": "garbage"}) == "us"


def test_unit_system_directive_us_mentions_us_units() -> None:
    text = unit_system_directive({})
    assert "US CUSTOMARY" in text
    assert "cups" in text and "tbsp" in text
    assert "°F" in text


def test_unit_system_directive_metric_mentions_metric_units() -> None:
    text = unit_system_directive({"unit_system": "metric"})
    assert "METRIC" in text
    assert " g" in text or text.startswith("UNIT SYSTEM — METRIC")
    assert "ml" in text
    assert "°C" in text


def test_week_planner_prompt_includes_unit_directive() -> None:
    """The full system prompt for week-plan generation must carry the
    unit directive so the AI doesn't drift to the other system."""
    from app.services.week_planner import _build_system_prompt

    metric_prompt = _build_system_prompt(
        {"unit_system": "metric"},
        date(2026, 5, 11),
        context=None,
    )
    assert "METRIC ONLY" in metric_prompt

    us_prompt = _build_system_prompt(
        {"unit_system": "us"},
        date(2026, 5, 11),
        context=None,
    )
    assert "US CUSTOMARY ONLY" in us_prompt


def test_event_per_dish_prompt_includes_unit_directive() -> None:
    """Per-dish AI recipe (M26 Phase 4) honors the unit toggle."""
    from app.services.event_ai import _build_per_dish_prompt
    from app.models import Event

    fake_event = Event(
        id="evt-1",
        user_id="u",
        household_id="h",
        name="Dinner Party",
        occasion="general",
        attendee_count=4,
    )
    fake_event.attendees = []  # type: ignore[attr-defined]

    prompt = _build_per_dish_prompt(
        event=fake_event,
        meal_name="Cheesy potatoes",
        servings=4,
        user_prompt="",
        user_settings={"unit_system": "metric"},
    )
    assert "METRIC ONLY" in prompt
