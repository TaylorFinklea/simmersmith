"""Household sharing API shapes (M21)."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class HouseholdMemberOut(BaseModel):
    user_id: str
    role: str
    joined_at: datetime


class HouseholdInvitationOut(BaseModel):
    code: str
    created_at: datetime
    expires_at: datetime
    created_by_user_id: str


class HouseholdOut(BaseModel):
    household_id: str
    name: str
    created_by_user_id: str
    role: str  # role of the requesting user
    members: list[HouseholdMemberOut]
    active_invitations: list[HouseholdInvitationOut]


class HouseholdRenameRequest(BaseModel):
    name: str = Field(..., max_length=120)


class JoinHouseholdRequest(BaseModel):
    code: str = Field(..., min_length=4, max_length=12)


class InvitationCreatedOut(BaseModel):
    code: str
    expires_at: datetime
