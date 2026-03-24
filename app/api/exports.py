from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db import get_session
from app.schemas import ExportCompleteRequest, ExportRunOut
from app.services.exports import apple_reminders_payload, complete_export_run, export_run_payload, get_export_run


router = APIRouter(prefix="/api/exports", tags=["exports"])


def load_export_or_404(session: Session, export_id: str):
    export_run = get_export_run(session, export_id)
    if export_run is None:
        raise HTTPException(status_code=404, detail="Export not found")
    return export_run


@router.get("/{export_id}", response_model=ExportRunOut)
def export_detail(export_id: str, session: Session = Depends(get_session)) -> dict[str, object]:
    return export_run_payload(load_export_or_404(session, export_id))


@router.get("/{export_id}/apple-reminders")
def export_apple_reminders_payload(export_id: str, session: Session = Depends(get_session)) -> dict[str, object]:
    export_run = load_export_or_404(session, export_id)
    if export_run.destination != "apple_reminders":
        raise HTTPException(status_code=400, detail="Export destination is not apple_reminders")
    return apple_reminders_payload(export_run)


@router.post("/{export_id}/complete", response_model=ExportRunOut)
def complete_export(
    export_id: str,
    payload: ExportCompleteRequest,
    session: Session = Depends(get_session),
) -> dict[str, object]:
    export_run = load_export_or_404(session, export_id)
    result = complete_export_run(session, export_run, payload)
    session.commit()
    session.expire_all()
    return result
