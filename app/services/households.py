"""Household lifecycle helpers (M21).

Resolves a user's household, creates solo households on first sign-in,
mints / claims invitations, and merges a joiner's solo content into the
target household when they accept an invitation.

Most callers want `get_household_id(session, user_id)` — fast path
through `household_members.user_id`. New users get a solo household
auto-created in `auth_apple` / `auth_google` so the lookup never
returns None for an authenticated user.
"""
from __future__ import annotations

import secrets
import string
from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import (
    Event,
    Guest,
    Household,
    HouseholdInvitation,
    HouseholdMember,
    Recipe,
    Staple,
    Week,
)
from app.models._base import new_id, utcnow

INVITATION_CODE_ALPHABET = string.ascii_uppercase + string.digits
INVITATION_CODE_LENGTH = 8
DEFAULT_INVITATION_TTL_DAYS = 7
SHARED_MODELS = (Week, Recipe, Staple, Event, Guest)


@dataclass(frozen=True)
class HouseholdSummary:
    id: str
    name: str
    created_by_user_id: str
    role: str  # role of the *requesting* user within this household


class HouseholdNotFoundError(RuntimeError):
    """Raised when a user has no household membership. Should never
    happen for an authenticated user post-M21."""


def get_household_id(session: Session, user_id: str) -> str:
    """Return the household_id this user belongs to.

    Single-membership-per-user is the v1 invariant. Raises
    `HouseholdNotFoundError` if the user has no membership row.
    """
    member = session.scalars(
        select(HouseholdMember).where(HouseholdMember.user_id == user_id).limit(1)
    ).first()
    if member is None:
        raise HouseholdNotFoundError(f"No household for user_id={user_id}")
    return member.household_id


def get_household_id_or_none(session: Session, user_id: str) -> str | None:
    """Same as `get_household_id` but returns None instead of raising.
    Used by `get_current_user` so a missing household doesn't 500 out."""
    member = session.scalars(
        select(HouseholdMember).where(HouseholdMember.user_id == user_id).limit(1)
    ).first()
    return member.household_id if member is not None else None


def get_household_summary(
    session: Session, user_id: str, household_id: str
) -> HouseholdSummary | None:
    household = session.get(Household, household_id)
    if household is None:
        return None
    member = session.scalars(
        select(HouseholdMember).where(
            HouseholdMember.household_id == household_id,
            HouseholdMember.user_id == user_id,
        )
    ).first()
    role = member.role if member is not None else "guest"
    return HouseholdSummary(
        id=household.id,
        name=household.name,
        created_by_user_id=household.created_by_user_id,
        role=role,
    )


def create_solo_household(
    session: Session, user_id: str, name: str = ""
) -> str:
    """Create a household with `user_id` as the sole owner. Returns the
    new household_id. Idempotent: if the user already has a membership,
    return its household_id without creating a duplicate."""
    existing = get_household_id_or_none(session, user_id)
    if existing is not None:
        return existing

    household = Household(
        id=new_id(),
        name=name or "",
        created_by_user_id=user_id,
        created_at=utcnow(),
        updated_at=utcnow(),
    )
    session.add(household)
    session.flush()
    member = HouseholdMember(
        id=new_id(),
        household_id=household.id,
        user_id=user_id,
        role="owner",
        joined_at=utcnow(),
    )
    session.add(member)
    session.flush()
    return household.id


def list_members(session: Session, household_id: str) -> list[HouseholdMember]:
    return list(
        session.scalars(
            select(HouseholdMember)
            .where(HouseholdMember.household_id == household_id)
            .order_by(HouseholdMember.joined_at)
        ).all()
    )


def list_active_invitations(
    session: Session, household_id: str
) -> list[HouseholdInvitation]:
    """Active = not yet claimed and not yet expired."""
    rows = session.scalars(
        select(HouseholdInvitation)
        .where(
            HouseholdInvitation.household_id == household_id,
            HouseholdInvitation.claimed_at.is_(None),
        )
        .order_by(HouseholdInvitation.created_at.desc())
    ).all()
    # Filter expired in Python so we tolerate SQLite's naive-datetime
    # storage (timezone comparisons can't push down across the dialects).
    now = utcnow()
    active: list[HouseholdInvitation] = []
    for inv in rows:
        expires_at = inv.expires_at
        if expires_at.tzinfo is None:
            compare_now = now.replace(tzinfo=None)
        else:
            compare_now = now
        if expires_at > compare_now:
            active.append(inv)
    return active


def _generate_invitation_code(session: Session) -> str:
    """8-char alphanumeric, uppercase. Uniqueness-checked against
    `household_invitations.code`. Loops until unique (collision odds
    are 1 in 36**8 ≈ 2.8 trillion; loop should rarely run twice)."""
    for _ in range(8):
        candidate = "".join(
            secrets.choice(INVITATION_CODE_ALPHABET)
            for _ in range(INVITATION_CODE_LENGTH)
        )
        existing = session.scalars(
            select(HouseholdInvitation).where(HouseholdInvitation.code == candidate)
        ).first()
        if existing is None:
            return candidate
    raise RuntimeError("Could not generate a unique invitation code in 8 tries")


def create_invitation(
    session: Session,
    *,
    household_id: str,
    created_by_user_id: str,
    ttl_days: int = DEFAULT_INVITATION_TTL_DAYS,
) -> HouseholdInvitation:
    """Mint a new invitation. Caller must already have verified that
    `created_by_user_id` is the household's owner."""
    invitation = HouseholdInvitation(
        id=new_id(),
        household_id=household_id,
        code=_generate_invitation_code(session),
        created_by_user_id=created_by_user_id,
        created_at=utcnow(),
        expires_at=utcnow() + timedelta(days=ttl_days),
    )
    session.add(invitation)
    session.flush()
    return invitation


class InvitationError(RuntimeError):
    """Base class for invitation-claim failures. Subclasses map to
    HTTP statuses in the API layer."""


class InvitationNotFoundError(InvitationError):
    """Code does not match any invitation (or has been revoked)."""


class InvitationExpiredError(InvitationError):
    """Invitation expired before claim, or was already claimed."""


class InvitationOwnHouseholdError(InvitationError):
    """The joining user is already a member of the inviting household."""


def claim_invitation(
    session: Session, *, code: str, joining_user_id: str
) -> Household:
    """Claim a code on behalf of `joining_user_id`. Migrates that
    user's solo-household content into the target household and
    deletes the empty solo household. Returns the target Household.

    Raises one of the InvitationError subclasses on failure.
    """
    code = (code or "").strip().upper()
    invitation = session.scalars(
        select(HouseholdInvitation).where(HouseholdInvitation.code == code)
    ).first()
    if invitation is None:
        raise InvitationNotFoundError(f"No invitation with code={code!r}")
    now = utcnow()
    if invitation.claimed_at is not None:
        raise InvitationExpiredError("Invitation has already been claimed.")
    # SQLite drops tzinfo on DateTime columns; PostgreSQL preserves it.
    # Normalize both sides to naive UTC for the comparison so the test
    # suite (SQLite) and prod (Postgres) behave identically.
    expires_at = invitation.expires_at
    if expires_at.tzinfo is None:
        compare_now = now.replace(tzinfo=None)
    else:
        compare_now = now
    if expires_at <= compare_now:
        raise InvitationExpiredError("Invitation has expired.")

    # Look up joiner's current household (created at first sign-in).
    joiner_household_id = get_household_id_or_none(session, joining_user_id)
    if joiner_household_id == invitation.household_id:
        raise InvitationOwnHouseholdError(
            "You are already a member of that household."
        )

    target_household = session.get(Household, invitation.household_id)
    if target_household is None:
        raise InvitationNotFoundError("Inviting household no longer exists.")

    # Auto-merge: re-point all of joiner's solo content at the target.
    if joiner_household_id is not None:
        merge_solo_into(
            session,
            joiner_user_id=joining_user_id,
            target_household_id=target_household.id,
        )

    # Add the joiner as a member of the target.
    new_member = HouseholdMember(
        id=new_id(),
        household_id=target_household.id,
        user_id=joining_user_id,
        role="member",
        joined_at=now,
    )
    session.add(new_member)

    # Mark the invitation claimed.
    invitation.claimed_by_user_id = joining_user_id
    invitation.claimed_at = now
    session.flush()
    return target_household


def merge_solo_into(
    session: Session,
    *,
    joiner_user_id: str,
    target_household_id: str,
) -> int:
    """Re-point the joiner's solo-household content (Weeks, Recipes,
    Staples, Events, Guests) at `target_household_id`, then delete
    the now-empty solo household + its membership row.

    Returns the count of rows updated across all shared tables. Safe
    to call when the joiner has no solo (returns 0).
    """
    solo_id = get_household_id_or_none(session, joiner_user_id)
    if solo_id is None or solo_id == target_household_id:
        return 0

    rows_updated = 0
    for model in SHARED_MODELS:
        result = session.execute(
            update(model)
            .where(model.household_id == solo_id)
            .values(household_id=target_household_id)
        )
        rows_updated += result.rowcount or 0

    # Drop the joiner's membership in their solo and the solo household
    # itself. ON DELETE CASCADE on household_members removes the row
    # automatically when we delete the Household, but we explicitly
    # delete the member first to be explicit about intent.
    session.execute(
        update(HouseholdInvitation)
        .where(
            HouseholdInvitation.household_id == solo_id,
            HouseholdInvitation.claimed_at.is_(None),
        )
        .values(
            # Mark any unclaimed invitations from the dying household as
            # claimed (by the joiner) so they can never be redeemed
            # against a non-existent household.
            claimed_by_user_id=joiner_user_id,
            claimed_at=utcnow(),
        )
    )
    member_row = session.scalars(
        select(HouseholdMember).where(
            HouseholdMember.household_id == solo_id,
            HouseholdMember.user_id == joiner_user_id,
        )
    ).first()
    if member_row is not None:
        session.delete(member_row)
    solo_household = session.get(Household, solo_id)
    if solo_household is not None:
        session.delete(solo_household)
    session.flush()
    return rows_updated


def revoke_invitation(session: Session, *, code: str, household_id: str) -> bool:
    """Mark an unclaimed invitation as expired. Returns True if revoked,
    False if not found / already claimed / already expired."""
    code = (code or "").strip().upper()
    invitation = session.scalars(
        select(HouseholdInvitation).where(
            HouseholdInvitation.code == code,
            HouseholdInvitation.household_id == household_id,
            HouseholdInvitation.claimed_at.is_(None),
        )
    ).first()
    if invitation is None:
        return False
    invitation.expires_at = utcnow()
    session.flush()
    return True
