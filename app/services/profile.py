from __future__ import annotations

from sqlalchemy import delete
from sqlalchemy.orm import Session

from app.models import Staple
from app.schemas import StaplePayload
from app.services.drafts import upsert_profile_settings
from app.services.grocery import normalize_name


def update_profile(
    session: Session,
    settings: dict[str, str],
    staples: list[StaplePayload] | None,
) -> None:
    if settings:
        upsert_profile_settings(session, {key: str(value) for key, value in settings.items()})

    if staples is None:
        session.flush()
        return

    session.execute(delete(Staple))
    seen: set[str] = set()
    for item in staples:
        normalized = normalize_name(item.normalized_name or item.staple_name)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        session.add(
            Staple(
                staple_name=item.staple_name.strip(),
                normalized_name=normalized,
                notes=item.notes,
                is_active=item.is_active,
            )
        )

    session.flush()
