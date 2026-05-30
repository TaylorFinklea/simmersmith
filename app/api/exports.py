from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.schemas import ExportCompleteRequest, ExportRunOut
from app.services.exports import apple_reminders_payload, complete_export_run, export_run_payload, get_export_run
from app.services.weeks import get_week


router = APIRouter(prefix="/api/exports", tags=["exports"])


def load_export_or_404(session: Session, export_id: str, household_id: str):
    """Load an export run, scoped to the caller's household.

    get_export_run looks up by primary key alone, so without the
    week-ownership check below any authenticated caller could read or
    mutate another household's export run by guessing/leaking its id
    (cross-household IDOR). We verify the run's week belongs to the
    household and return 404 (not 403) on mismatch so we don't confirm
    the id exists.
    """
    export_run = get_export_run(session, export_id)
    if export_run is None:
        raise HTTPException(status_code=404, detail="Export not found")
    if get_week(session, household_id, export_run.week_id) is None:
        raise HTTPException(status_code=404, detail="Export not found")
    return export_run


@router.get("/{export_id}", response_model=ExportRunOut)
def export_detail(
    export_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    return export_run_payload(load_export_or_404(session, export_id, current_user.household_id))


@router.get("/{export_id}/apple-reminders")
def export_apple_reminders_payload(
    export_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    export_run = load_export_or_404(session, export_id, current_user.household_id)
    if export_run.destination != "apple_reminders":
        raise HTTPException(status_code=400, detail="Export destination is not apple_reminders")
    return apple_reminders_payload(export_run)


@router.post("/{export_id}/complete", response_model=ExportRunOut)
def complete_export(
    export_id: str,
    payload: ExportCompleteRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    export_run = load_export_or_404(session, export_id, current_user.household_id)
    result = complete_export_run(session, export_run, payload)
    session.commit()
    session.expire_all()
    return result
