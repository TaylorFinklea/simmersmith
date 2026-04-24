from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import PreferenceSignal, ProfileSetting, utcnow
from app.schemas import MealScoreRequest, PreferenceSignalPayload
from app.services.grocery import normalize_name


VALID_SIGNAL_TYPES = {"meal", "ingredient", "brand", "pattern", "cuisine"}


def normalize_signal_type(value: str) -> str:
    normalized = normalize_name(value).replace(" ", "_")
    aliases = {
        "meals": "meal",
        "ingredients": "ingredient",
        "brands": "brand",
        "patterns": "pattern",
        "cuisines": "cuisine",
    }
    signal_type = aliases.get(normalized, normalized)
    if signal_type not in VALID_SIGNAL_TYPES:
        raise ValueError(f"Unsupported signal_type '{value}'.")
    return signal_type


def list_preference_signals(session: Session, user_id: str) -> list[PreferenceSignal]:
    return session.scalars(
        select(PreferenceSignal)
        .where(PreferenceSignal.user_id == user_id)
        .order_by(PreferenceSignal.signal_type, PreferenceSignal.name)
    ).all()


def upsert_preference_signals(session: Session, user_id: str, signals: list[PreferenceSignalPayload]) -> list[PreferenceSignal]:
    stored: list[PreferenceSignal] = []
    for payload in signals:
        signal_type = normalize_signal_type(payload.signal_type)
        normalized_name = normalize_name(payload.normalized_name or payload.name)
        if not normalized_name:
            continue

        signal = None
        if payload.preference_id:
            signal = session.get(PreferenceSignal, payload.preference_id)
        if signal is None:
            signal = session.scalar(
                select(PreferenceSignal).where(
                    PreferenceSignal.user_id == user_id,
                    PreferenceSignal.signal_type == signal_type,
                    PreferenceSignal.normalized_name == normalized_name,
                )
            )
        if signal is None:
            signal = PreferenceSignal(user_id=user_id, signal_type=signal_type, normalized_name=normalized_name, name=payload.name.strip())
            session.add(signal)

        signal.signal_type = signal_type
        signal.name = payload.name.strip()
        signal.normalized_name = normalized_name
        signal.score = payload.score
        signal.weight = payload.weight
        signal.rationale = payload.rationale
        signal.source = payload.source
        signal.active = payload.active
        signal.updated_at = utcnow()
        stored.append(signal)

    session.flush()
    return stored


def preference_signal_payload(signal: PreferenceSignal) -> dict[str, object]:
    return {
        "preference_id": signal.id,
        "signal_type": signal.signal_type,
        "name": signal.name,
        "normalized_name": signal.normalized_name,
        "score": signal.score,
        "weight": signal.weight,
        "rationale": signal.rationale,
        "source": signal.source,
        "active": signal.active,
    }


def load_profile_settings(session: Session, user_id: str) -> dict[str, str]:
    return {
        setting.key: setting.value
        for setting in session.scalars(
            select(ProfileSetting)
            .where(ProfileSetting.user_id == user_id)
            .order_by(ProfileSetting.key)
        ).all()
    }


def preference_summary_payload(session: Session, user_id: str, signals: list[PreferenceSignal] | None = None) -> dict[str, list[str]]:
    settings = load_profile_settings(session, user_id)
    signals = signals or list_preference_signals(session, user_id)
    active_signals = [signal for signal in signals if signal.active]

    hard_avoids = sorted(
        signal.name
        for signal in active_signals
        if signal.score <= -4 or (signal.signal_type == "ingredient" and signal.score < 0)
    )
    strong_likes = sorted(signal.name for signal in active_signals if signal.score >= 4)
    brands = sorted(signal.name for signal in active_signals if signal.signal_type == "brand" and signal.score > 0)

    rules: list[str] = []
    adults = settings.get("household_adults", "")
    kids = settings.get("household_kids", "")
    if adults or kids:
        parts = []
        if adults:
            parts.append(f"{adults} adults")
        if kids:
            parts.append(f"{kids} young kids")
        rules.append(f"Household: {', '.join(parts)}.")
    if settings.get("monthly_grocery_budget_usd"):
        rules.append(f"Monthly grocery budget target: ${settings['monthly_grocery_budget_usd']}.")
    if settings.get("food_principles"):
        rules.append(settings["food_principles"])
    if settings.get("convenience_rules"):
        rules.append(settings["convenience_rules"])
    if settings.get("breakfast_strategy"):
        rules.append(settings["breakfast_strategy"])
    if settings.get("lunch_strategy"):
        rules.append(settings["lunch_strategy"])
    if settings.get("snack_strategy"):
        rules.append(settings["snack_strategy"])
    if settings.get("leftovers_policy"):
        rules.append(settings["leftovers_policy"])
    if settings.get("portable_lunch_days"):
        rules.append(f"Portable lunches preferred on: {settings['portable_lunch_days']}.")
    if settings.get("saturday_dinner_plan"):
        rules.append(settings["saturday_dinner_plan"])

    return {
        "hard_avoids": hard_avoids,
        "strong_likes": strong_likes,
        "brands": brands,
        "rules": rules,
    }


def contains_phrase(value: str, phrase: str) -> bool:
    return bool(value and phrase and phrase in value)


def score_meal_candidate(session: Session, user_id: str, payload: MealScoreRequest) -> dict[str, object]:
    from app.services.ingredient_catalog.variation import list_ingredient_preferences

    signals = [signal for signal in list_preference_signals(session, user_id) if signal.active]
    normalized_name = normalize_name(payload.recipe_name)
    normalized_cuisine = normalize_name(payload.cuisine)
    ingredient_names = {normalize_name(item) for item in payload.ingredient_names if item}
    tags = {normalize_name(item) for item in payload.tags if item}
    tag_blob = " ".join(sorted(tags))

    total_score = 0
    blockers: list[str] = []
    matches: list[dict[str, object]] = []

    # Catalog-level avoid / allergy preferences flip `blocked=True` too.
    # This is defense-in-depth — the planner prompt already excludes them,
    # but a slip-through (wrong variant, ambiguous name) still gets caught
    # in post-generation scoring.
    for pref in list_ingredient_preferences(session, user_id):
        if not pref.active:
            continue
        if pref.choice_mode not in {"avoid", "allergy"}:
            continue
        ingredient_name = pref.base_ingredient.name if pref.base_ingredient else ""
        if not ingredient_name:
            continue
        if normalize_name(ingredient_name) in ingredient_names:
            label = "Allergy" if pref.choice_mode == "allergy" else "Avoid ingredient"
            blockers.append(f"{label}: {ingredient_name}")
            total_score -= 10
            matches.append(
                {
                    "preference_id": pref.id,
                    "signal_type": pref.choice_mode,
                    "name": ingredient_name,
                    "contribution": -10,
                    "rationale": f"User flagged {ingredient_name} as {pref.choice_mode}.",
                }
            )

    for signal in signals:
        contribution = 0
        weighted_value = signal.score * signal.weight

        if signal.signal_type == "meal" and (
            contains_phrase(normalized_name, signal.normalized_name)
            or contains_phrase(signal.normalized_name, normalized_name)
        ):
            contribution = weighted_value
        elif signal.signal_type == "ingredient" and signal.normalized_name in ingredient_names:
            contribution = weighted_value * 2
            if signal.score <= -4:
                blockers.append(f"Avoid ingredient: {signal.name}")
        elif signal.signal_type == "cuisine" and signal.normalized_name == normalized_cuisine:
            contribution = weighted_value
        elif signal.signal_type == "brand" and (
            contains_phrase(normalized_name, signal.normalized_name) or contains_phrase(tag_blob, signal.normalized_name)
        ):
            contribution = weighted_value
        elif signal.signal_type == "pattern" and (
            contains_phrase(normalized_name, signal.normalized_name) or contains_phrase(tag_blob, signal.normalized_name)
        ):
            contribution = weighted_value

        if contribution == 0:
            continue

        total_score += contribution
        matches.append(
            {
                "preference_id": signal.id,
                "signal_type": signal.signal_type,
                "name": signal.name,
                "contribution": contribution,
                "rationale": signal.rationale,
            }
        )

    matches.sort(key=lambda item: abs(int(item["contribution"])), reverse=True)
    return {
        "total_score": total_score,
        "blocked": bool(blockers),
        "blockers": blockers,
        "matches": matches,
    }


def preference_context_payload(session: Session, user_id: str) -> dict[str, object]:
    signals = list_preference_signals(session, user_id)
    return {
        "signals": [preference_signal_payload(signal) for signal in signals],
        "summary": preference_summary_payload(session, user_id, signals),
    }
