from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from app.models import Week, WeekChangeBatch, WeekChangeEvent, WeekMeal


def stringify_change_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def build_change_event(
    *,
    entity_type: str,
    entity_id: str,
    field_name: str,
    before_value: Any,
    after_value: Any,
) -> dict[str, str]:
    return {
        "entity_type": entity_type,
        "entity_id": entity_id,
        "field_name": field_name,
        "before_value": stringify_change_value(before_value),
        "after_value": stringify_change_value(after_value),
    }


def record_change_batch(
    session: Session,
    week: Week,
    *,
    actor_type: str,
    actor_label: str,
    summary: str,
    changes: list[dict[str, str]],
) -> WeekChangeBatch | None:
    if not changes:
        return None

    batch = WeekChangeBatch(
        week_id=week.id,
        actor_type=actor_type,
        actor_label=actor_label,
        summary=summary,
    )
    session.add(batch)
    session.flush()

    for change in changes:
        session.add(
            WeekChangeEvent(
                batch_id=batch.id,
                entity_type=change["entity_type"],
                entity_id=change["entity_id"],
                field_name=change["field_name"],
                before_value=change["before_value"],
                after_value=change["after_value"],
            )
        )

    session.flush()
    return batch


def ai_baseline_changes(meals: list[WeekMeal]) -> list[dict[str, str]]:
    changes: list[dict[str, str]] = []
    for meal in meals:
        changes.extend(
            [
                build_change_event(
                    entity_type="meal",
                    entity_id=meal.id,
                    field_name="recipe_name",
                    before_value="",
                    after_value=meal.recipe_name,
                ),
                build_change_event(
                    entity_type="meal",
                    entity_id=meal.id,
                    field_name="recipe_id",
                    before_value="",
                    after_value=meal.recipe_id,
                ),
                build_change_event(
                    entity_type="meal",
                    entity_id=meal.id,
                    field_name="servings",
                    before_value="",
                    after_value=meal.servings,
                ),
                build_change_event(
                    entity_type="meal",
                    entity_id=meal.id,
                    field_name="approved",
                    before_value="",
                    after_value=meal.approved,
                ),
                build_change_event(
                    entity_type="meal",
                    entity_id=meal.id,
                    field_name="notes",
                    before_value="",
                    after_value=meal.notes,
                ),
            ]
        )
    return changes
