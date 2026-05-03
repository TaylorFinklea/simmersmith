"""Event Plans REST endpoints — guest CRUD + event CRUD. AI menu
generation and grocery merge land in Phases 2 + 3 of M10.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.config import Settings, get_settings
from app.schemas import (
    EventCreateRequest,
    EventGroceryMergeRequest,
    EventMealCreateRequest,
    EventMealUpdateRequest,
    EventMenuGenerateRequest,
    EventMenuGenerateResponse,
    EventOut,
    EventSummaryOut,
    EventUpdateRequest,
    GuestOut,
    GuestPayload,
)
from app.services.ai import profile_settings_map
from app.services.event_presenters import (
    event_payload,
    event_summary_payload,
    guest_payload,
)
from app.services.events import (
    add_event_meal,
    create_event,
    delete_event,
    delete_event_meal,
    delete_guest,
    get_event,
    list_events,
    list_guests,
    update_event,
    update_event_meal,
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
    return [guest_payload(g) for g in list_guests(session, current_user.household_id, include_inactive=include_inactive)]


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
            current_user.household_id,
            guest_id=payload.guest_id,
            name=payload.name,
            relationship_label=payload.relationship_label,
            dietary_notes=payload.dietary_notes,
            allergies=payload.allergies,
            age_group=payload.age_group,
            active=payload.active,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(guest)
    return guest_payload(guest)


@guests_router.delete("/{guest_id}")
def delete_guest_route(
    guest_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    if not delete_guest(session, current_user.household_id, guest_id):
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
    return [event_summary_payload(e) for e in list_events(session, current_user.household_id)]


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
            current_user.household_id,
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
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=500, detail="Event vanished after create")
        return event_payload(fresh)


@events_router.get("/{event_id}", response_model=EventOut)
def get_event_route(
    event_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    event = get_event(session, current_user.household_id, event_id)
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
    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    attendees = (
        [(a.guest_id, a.plus_ones) for a in payload.attendees]
        if payload.attendees is not None
        else None
    )
    set_fields = payload.model_fields_set
    auto_merge_kwarg: dict[str, object] = (
        {"auto_merge_grocery": payload.auto_merge_grocery}
        if "auto_merge_grocery" in set_fields
        else {}
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
            household_id=current_user.household_id,
            **auto_merge_kwarg,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    # Reconcile auto-merge after the toggle (or event_date) changes.
    from app.services.event_grocery import apply_auto_merge_policy

    apply_auto_merge_policy(
        session,
        event=event,
        user_id=current_user.id,
        household_id=current_user.household_id,
    )
    session.commit()
    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return event_payload(fresh)


@events_router.delete("/{event_id}")
def delete_event_route(
    event_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    delete_event(session, event)
    session.commit()
    return Response(status_code=204)


@events_router.post("/{event_id}/meals", response_model=EventOut)
def add_event_meal_route(
    event_id: str,
    payload: EventMealCreateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Manually add a dish to the event. Use for "Kirsten is bringing
    salad" or just "+ Add another side" after the AI generated the
    core menu.
    """
    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    try:
        add_event_meal(
            session,
            event,
            role=payload.role,
            recipe_id=payload.recipe_id,
            recipe_name=payload.recipe_name,
            servings=payload.servings,
            notes=payload.notes,
            assigned_guest_id=payload.assigned_guest_id,
            household_id=current_user.household_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()

    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return event_payload(fresh)


@events_router.patch("/{event_id}/meals/{meal_id}", response_model=EventOut)
def update_event_meal_route(
    event_id: str,
    meal_id: str,
    payload: EventMealUpdateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    try:
        update_event_meal(
            session,
            event,
            meal_id,
            role=payload.role,
            recipe_id=payload.recipe_id,
            recipe_name=payload.recipe_name,
            servings=payload.servings,
            notes=payload.notes,
            assigned_guest_id=payload.assigned_guest_id,
            clear_assignee=payload.clear_assignee,
            household_id=current_user.household_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()

    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return event_payload(fresh)


@events_router.delete("/{event_id}/meals/{meal_id}", response_model=EventOut)
def delete_event_meal_route(
    event_id: str,
    meal_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    if not delete_event_meal(session, event, meal_id):
        raise HTTPException(status_code=404, detail="Meal not found")
    session.commit()

    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return event_payload(fresh)


@events_router.post("/{event_id}/ai/menu", response_model=EventMenuGenerateResponse)
def generate_event_menu_route(
    event_id: str,
    payload: EventMenuGenerateRequest,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Ask the AI to design a menu for this event. Replaces any existing
    EventMeals — this is a full regenerate, not an additive operation.
    Also regenerates the event's grocery list so the response carries
    both. Returns the hydrated event + a `coverage_summary`.
    """
    from app.services.event_ai import generate_event_menu
    from app.services.event_grocery import regenerate_event_grocery

    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")

    user_settings = profile_settings_map(session, current_user.id)
    try:
        result = generate_event_menu(
            session=session,
            event=event,
            user_prompt=payload.prompt,
            roles=payload.roles,
            settings=settings,
            user_settings=user_settings,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    # After meals land we eagerly regenerate the grocery list so the
    # user can see produce/protein/pantry totals alongside the menu.
    # Expire the cached `meals` relation first — replace_event_meals
    # deleted + recreated the rows but the Python attribute still holds
    # the stale list until we flush + expire.
    session.flush()
    session.expire(event, ["meals"])
    regenerate_event_grocery(session, current_user.id, event)
    from app.services.event_grocery import apply_auto_merge_policy
    apply_auto_merge_policy(
        session,
        event=event,
        user_id=current_user.id,
        household_id=current_user.household_id,
    )
    session.commit()

    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return {
            "event": event_payload(fresh),
            "coverage_summary": result.get("coverage_summary", ""),
        }


@events_router.post("/{event_id}/grocery/refresh", response_model=EventOut)
def refresh_event_grocery_route(
    event_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Recompute the event's grocery list from its current meals. Useful
    when the user has edited meals after the initial AI generation."""
    from app.services.event_grocery import apply_auto_merge_policy, regenerate_event_grocery

    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    regenerate_event_grocery(session, current_user.id, event)
    apply_auto_merge_policy(
        session,
        event=event,
        user_id=current_user.id,
        household_id=current_user.household_id,
    )
    session.commit()

    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return event_payload(fresh)


@events_router.post("/{event_id}/grocery/merge", response_model=EventOut)
def merge_event_grocery_route(
    event_id: str,
    payload: EventGroceryMergeRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Fold the event's grocery list into the given week's grocery list.
    Matching rows combine quantities; rows with no match are added as
    new GroceryItems attributed to the event. Idempotent.
    """
    from app.models import Week
    from app.services.event_grocery import merge_event_into_week

    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")

    week = session.scalar(
        select(Week).where(Week.id == payload.week_id, Week.household_id == current_user.household_id)
    )
    if week is None:
        raise HTTPException(status_code=404, detail="Week not found")

    merge_event_into_week(session, user_id=current_user.id, event=event, week=week)
    session.commit()

    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return event_payload(fresh)


@events_router.delete("/{event_id}/grocery/merge", response_model=EventOut)
def unmerge_event_grocery_route(
    event_id: str,
    week_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Reverse a prior merge from the specified week."""
    from app.models import Week
    from app.services.event_grocery import unmerge_event_from_week

    event = get_event(session, current_user.household_id, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="Event not found")
    week = session.scalar(
        select(Week).where(Week.id == week_id, Week.household_id == current_user.household_id)
    )
    if week is None:
        raise HTTPException(status_code=404, detail="Week not found")
    unmerge_event_from_week(session, event=event, week=week)
    session.commit()

    from app.db import session_scope

    with session_scope() as read_session:
        fresh = get_event(read_session, current_user.household_id, event_id)
        if fresh is None:
            raise HTTPException(status_code=404, detail="Event not found")
        return event_payload(fresh)
