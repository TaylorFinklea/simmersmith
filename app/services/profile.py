from __future__ import annotations

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import DietaryGoal, Staple
from app.schemas import DietaryGoalPayload, StaplePayload
from app.services.drafts import upsert_profile_settings
from app.services.grocery import normalize_name


def update_profile(
    session: Session,
    user_id: str,
    household_id: str,
    settings: dict[str, str],
    staples: list[StaplePayload] | None,
) -> None:
    if settings:
        upsert_profile_settings(session, user_id, {key: str(value) for key, value in settings.items()})

    if staples is None:
        session.flush()
        return

    session.execute(delete(Staple).where(Staple.household_id == household_id))
    seen: set[str] = set()
    for item in staples:
        normalized = normalize_name(item.normalized_name or item.staple_name)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        session.add(
            Staple(
                user_id=user_id,
                household_id=household_id,
                staple_name=item.staple_name.strip(),
                normalized_name=normalized,
                notes=item.notes,
                is_active=item.is_active,
            )
        )

    session.flush()


def get_dietary_goal(session: Session, user_id: str) -> DietaryGoal | None:
    return session.scalar(select(DietaryGoal).where(DietaryGoal.user_id == user_id))


def upsert_dietary_goal(
    session: Session,
    user_id: str,
    payload: DietaryGoalPayload,
) -> DietaryGoal:
    goal = get_dietary_goal(session, user_id)
    if goal is None:
        goal = DietaryGoal(user_id=user_id)
        session.add(goal)
    goal.goal_type = payload.goal_type
    goal.daily_calories = int(payload.daily_calories)
    goal.protein_g = int(payload.protein_g)
    goal.carbs_g = int(payload.carbs_g)
    goal.fat_g = int(payload.fat_g)
    goal.fiber_g = int(payload.fiber_g) if payload.fiber_g is not None else None
    goal.notes = payload.notes.strip()
    session.flush()
    return goal


def delete_dietary_goal(session: Session, user_id: str) -> None:
    session.execute(delete(DietaryGoal).where(DietaryGoal.user_id == user_id))
    session.flush()


def preset_macros(goal_type: str, daily_calories: int) -> tuple[int, int, int]:
    """Return (protein_g, carbs_g, fat_g) for a preset goal type.

    Splits come from standard macro-distribution guidance. "custom" should
    not use this — callers pass raw macros directly.

    - lose:     40% P / 30% C / 30% F
    - maintain: 30% P / 45% C / 25% F
    - gain:     30% P / 45% C / 25% F (at a higher calorie target)
    """
    if goal_type == "lose":
        protein_ratio, carbs_ratio, fat_ratio = 0.40, 0.30, 0.30
    elif goal_type == "gain":
        protein_ratio, carbs_ratio, fat_ratio = 0.30, 0.45, 0.25
    else:  # maintain or unknown
        protein_ratio, carbs_ratio, fat_ratio = 0.30, 0.45, 0.25
    protein_g = int(round((daily_calories * protein_ratio) / 4))
    carbs_g = int(round((daily_calories * carbs_ratio) / 4))
    fat_g = int(round((daily_calories * fat_ratio) / 9))
    return protein_g, carbs_g, fat_g
