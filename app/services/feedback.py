from __future__ import annotations

import json
from collections import defaultdict

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import FeedbackEntry, PreferenceSignal, Week, utcnow
from app.schemas import FeedbackEntryPayload
from app.services.grocery import normalize_name

PREFERENCE_FEEDBACK_TYPES = {"meal", "ingredient", "brand"}


def list_feedback_entries(session: Session, week_id: str) -> list[FeedbackEntry]:
    return list(
        session.scalars(
            select(FeedbackEntry).where(FeedbackEntry.week_id == week_id).order_by(FeedbackEntry.created_at.desc())
        ).all()
    )


def feedback_summary_payload(entries: list[FeedbackEntry]) -> dict[str, int]:
    summary = defaultdict(int)
    summary["total_entries"] = len(entries)
    summary["shopping_entries"] = 0
    for entry in entries:
        if entry.target_type == "shopping_item":
            summary["shopping_entries"] += 1
        else:
            summary[f"{entry.target_type}_entries"] += 1
    return {
        "total_entries": summary["total_entries"],
        "meal_entries": summary["meal_entries"],
        "ingredient_entries": summary["ingredient_entries"],
        "brand_entries": summary["brand_entries"],
        "shopping_entries": summary["shopping_entries"],
        "store_entries": summary["store_entries"],
        "week_entries": summary["week_entries"],
    }


def feedback_entry_payload(entry: FeedbackEntry) -> dict[str, object]:
    try:
        reason_codes = json.loads(entry.reason_codes or "[]")
    except json.JSONDecodeError:
        reason_codes = []
    return {
        "feedback_id": entry.id,
        "meal_id": entry.meal_id,
        "grocery_item_id": entry.grocery_item_id,
        "target_type": entry.target_type,
        "target_name": entry.target_name,
        "normalized_name": entry.normalized_name,
        "retailer": entry.retailer,
        "sentiment": entry.sentiment,
        "reason_codes": reason_codes if isinstance(reason_codes, list) else [],
        "notes": entry.notes,
        "source": entry.source,
        "active": entry.active,
        "created_at": entry.created_at,
        "updated_at": entry.updated_at,
    }


def _upsert_feedback_signal(
    session: Session,
    *,
    signal_type: str,
    name: str,
    normalized_name: str,
    score: int,
    weight: int,
    rationale: str,
) -> None:
    manual_signal = session.scalar(
        select(PreferenceSignal).where(
            PreferenceSignal.signal_type == signal_type,
            PreferenceSignal.normalized_name == normalized_name,
            PreferenceSignal.source != "feedback",
        )
    )
    feedback_signal = session.scalar(
        select(PreferenceSignal).where(
            PreferenceSignal.signal_type == signal_type,
            PreferenceSignal.normalized_name == normalized_name,
            PreferenceSignal.source == "feedback",
        )
    )

    if manual_signal is not None:
        if feedback_signal is not None:
            feedback_signal.active = False
            feedback_signal.updated_at = utcnow()
        return

    if feedback_signal is None:
        feedback_signal = PreferenceSignal(
            signal_type=signal_type,
            name=name,
            normalized_name=normalized_name,
            source="feedback",
        )
        session.add(feedback_signal)

    feedback_signal.name = name
    feedback_signal.score = score
    feedback_signal.weight = weight
    feedback_signal.rationale = rationale
    feedback_signal.active = True
    feedback_signal.updated_at = utcnow()


def rebuild_feedback_preference_signals(session: Session) -> None:
    entries = list(
        session.scalars(
            select(FeedbackEntry).where(
                FeedbackEntry.active.is_(True),
                FeedbackEntry.target_type.in_(PREFERENCE_FEEDBACK_TYPES),
            )
        ).all()
    )

    aggregates: dict[tuple[str, str], dict[str, object]] = {}
    for entry in entries:
        if entry.sentiment == 0:
            continue
        key = (entry.target_type, entry.normalized_name)
        bucket = aggregates.setdefault(
            key,
            {
                "name": entry.target_name,
                "total": 0,
                "count": 0,
            },
        )
        bucket["name"] = entry.target_name
        bucket["total"] = int(bucket["total"]) + entry.sentiment
        bucket["count"] = int(bucket["count"]) + 1

    active_feedback_keys: set[tuple[str, str]] = set()
    for (signal_type, normalized_name), aggregate in aggregates.items():
        active_feedback_keys.add((signal_type, normalized_name))
        total = max(-5, min(5, int(aggregate["total"])))
        weight = max(1, min(5, int(aggregate["count"])))
        rationale = f"Derived from {aggregate['count']} feedback entr{'y' if aggregate['count'] == 1 else 'ies'}."
        _upsert_feedback_signal(
            session,
            signal_type=signal_type,
            name=str(aggregate["name"]),
            normalized_name=normalized_name,
            score=total,
            weight=weight,
            rationale=rationale,
        )

    existing_feedback_signals = session.scalars(
        select(PreferenceSignal).where(PreferenceSignal.source == "feedback")
    ).all()
    for signal in existing_feedback_signals:
        if (signal.signal_type, signal.normalized_name) not in active_feedback_keys:
            signal.active = False
            signal.updated_at = utcnow()

    session.flush()


def upsert_feedback_entries(session: Session, week: Week, entries: list[FeedbackEntryPayload]) -> list[FeedbackEntry]:
    stored: list[FeedbackEntry] = []
    for payload in entries:
        normalized_name = normalize_name(payload.normalized_name or payload.target_name)
        if not normalized_name:
            continue

        entry = session.get(FeedbackEntry, payload.feedback_id) if payload.feedback_id else None
        if entry is None:
            entry = FeedbackEntry(week_id=week.id, target_type=payload.target_type, target_name=payload.target_name)
            session.add(entry)

        entry.week_id = week.id
        entry.meal_id = payload.meal_id
        entry.grocery_item_id = payload.grocery_item_id
        entry.target_type = payload.target_type
        entry.target_name = payload.target_name.strip()
        entry.normalized_name = normalized_name
        entry.retailer = payload.retailer
        entry.sentiment = payload.sentiment
        entry.reason_codes = json.dumps(payload.reason_codes)
        entry.notes = payload.notes
        entry.source = payload.source
        entry.active = payload.active
        entry.updated_at = utcnow()
        stored.append(entry)

    session.flush()
    rebuild_feedback_preference_signals(session)
    return stored


def feedback_response_payload(session: Session, week: Week) -> dict[str, object]:
    entries = list_feedback_entries(session, week.id)
    return {
        "week_id": week.id,
        "summary": feedback_summary_payload(entries),
        "entries": [feedback_entry_payload(entry) for entry in entries],
    }
