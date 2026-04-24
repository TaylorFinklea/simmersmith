"""Event Plans REST endpoints — guest CRUD + event CRUD. AI menu
generation and grocery merge land in Phases 2 + 3 of M10.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.schemas import (
    EventCreateRequest,
    EventOut,
    EventSummaryOut,
    EventUpdateRequest,
    GuestOut,
    GuestPayload,
)
from app.services.event_presenters import (
    event_payload,
    event_summary_payload,
    guest_payload,
)
from app.services.events import (
    create_event,
    delete_event,
    delete_guest,
    get_event,
    list_events,
    list_guests,
    update_event,
    upsert_guest,
)


events_router = APIRouter(prefix="/api/events", tags=["events"])
guests_router = APIRouter(prefix="/api/guests", tags=["events"])


# ---------------------------------------------------------------------
# Guests
# ---------------------------------------------------------------------

@guests_router.get("", response_model=list[GuestOut])
def list_guests_route(
    include_inactive: bool = False,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    return [guest_payload(g) for g in list_guests(session, current_user.id, include_inactive=include_inactive)]


@guests_router.post("", response_model=GuestOut)
def upsert_guest_route(
    payload: GuestPayload,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    try:
        guest = upsert_guest(
            session,
            current_user.id,
            guest_id=payload.guest_id,
            name=payload.name,
            relationship_label=payload.relationship_label,
            dietary_notes=payload.dietary_notes,
            allergies=payload.allergies,
            active=payload.active,
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    session.commit()
    session.refresh(guest)
    return guest_payload(guest)


@guests_router.delete("/{guest_id}")
def delete_guest_route(
    guest_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    if not delete_guest(session, current_user.id, guest_id):
        raise HTTPException(status_code=404, detail="Guest not found")
    session.commit()
    return Response(status_code=204)


# ---------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------

@events_router.get("", response_model=list[EventSummaryOut])
def list_events_route(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    return [event_summary_payload(e) for e in list_events(session, current_user.id)]


@events_router.post("", response_model=EventOut)
def create_event_route(
    payload: EventCreateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    attendees = [(a.guest_id, a.plus_ones) for a in payload.attendees]
    try:
        event = create_event(
            session,
            current_user.id,
            name=payload.name,
            event_date=payload.event_date,
            occasion=payload.occasion,
            attendee_count=payload.attendee_count,
            notes=payload.notes,
            attendees=attendees,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    event_id = event.id
    session.commit()
    # Re-fetch in a fresh scope — after commit the original `event` object
    # is expired and lazy-loading the attendees/meals relationships from
    # the still-bound session can race. A clean session_scope gives us a
    # fully hydrated tree via selectinload.
    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.id, event_id)
        if fresh is None:
            raise HTTPException(status_code=500, detail="Event vanished after create")
        return event_payload(fresh)


@events_router.get("/{event_id}", response_model=EventOut)
def get_event_route(
    event_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    event = get_event(session, current_user.id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    return event_payload(event)


@events_router.patch("/{event_id}", response_model=EventOut)
def update_event_route(
    event_id: str,
    payload: EventUpdateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    event = get_event(session, current_user.id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    attendees = (
        [(a.guest_id, a.plus_ones) for a in payload.attendees]
        if payload.attendees is not None
        else None
    )
    try:
        update_event(
            session,
            event,
            name=payload.name,
            event_date=payload.event_date,
            occasion=payload.occasion,
            attendee_count=payload.attendee_count,
            notes=payload.notes,
            status=payload.status,
            attendees=attendees,
            user_id=current_user.id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return event_payload(fresh)


@events_router.delete("/{event_id}")
def delete_event_route(
    event_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    event = get_event(session, current_user.id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    delete_event(session, event)
    session.commit()
    return Response(status_code=204)
