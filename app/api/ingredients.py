from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.models import IngredientVariation
from app.schemas import (
    BaseIngredientDetailOut,
    BaseIngredientOut,
    BaseIngredientPayload,
    IngredientMergeRequest,
    IngredientPreferenceOut,
    IngredientPreferencePayload,
    IngredientResolveOut,
    IngredientResolveRequest,
    IngredientVariationOut,
    IngredientVariationPayload,
)
from app.services.ingredient_catalog import (
    create_or_update_variation,
    ensure_base_ingredient,
    get_base_ingredient,
    ingredient_counts,
    ingredient_counts_bulk,
    ingredient_preference_for_base,
    ingredient_usage_summary,
    is_product_like_base_ingredient,
    list_ingredient_preferences,
    list_variations,
    merge_base_ingredients,
    merge_variations,
    resolve_ingredient,
    search_base_ingredients,
    archive_base_ingredient,
    archive_variation,
    update_base_ingredient,
    update_variation,
    upsert_ingredient_preference,
)


from app.api.admin import require_admin_bearer

router = APIRouter(prefix="/api/ingredients", tags=["ingredients"])
preferences_router = APIRouter(prefix="/api/ingredient-preferences", tags=["ingredients"])


def _require_owned_base_ingredient(session: Session, base_ingredient_id: str, household_id: str):
    """Block a household from mutating ANOTHER household's private ingredient.

    Catalog governance here is intentionally collaborative: the global
    `approved` rows (household_id NULL) are shared and remain editable by
    any household (the resolver falls through to them, and
    test_ingredient_catalog_merge_and_archive_routes codifies household
    merge/archive of them). What is NOT allowed is reaching into another
    household's `household_only` (private) row by id — that was a real
    cross-tenant IDOR. So: allow own rows + the shared global catalog;
    reject a row owned by a different household. (Internal resolution
    flows call the services directly, not these routes, so are unaffected.
    Locking the global catalog to admins is a separate product decision.)
    """
    item = get_base_ingredient(session, base_ingredient_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Base ingredient not found")
    if item.household_id is not None and item.household_id != household_id:
        # Don't reveal that another household's private row exists.
        raise HTTPException(status_code=404, detail="Base ingredient not found")
    return item


def _require_visible_base_ingredient(session: Session, base_ingredient_id: str, household_id: str):
    """Authorize a READ of a base ingredient — mirrors the search/list
    visibility rule (NOT the stricter mutation-ownership rule).

    A household may read the global `approved` catalog AND its own
    household rows, but not another household's private (household_only /
    submitted / rejected) row. The detail + variations GET routes looked
    rows up by id with no visibility filter, leaking another household's
    private ingredient/variation data (cross-tenant IDOR read). 404 (not
    403) so we don't reveal the row exists.
    """
    item = get_base_ingredient(session, base_ingredient_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Base ingredient not found")
    if item.submission_status != "approved" and item.household_id != household_id:
        raise HTTPException(status_code=404, detail="Base ingredient not found")
    return item


def _require_owned_variation(session: Session, ingredient_variation_id: str, household_id: str):
    """A variation inherits ownership from its base ingredient."""
    variation = session.get(IngredientVariation, ingredient_variation_id)
    if variation is None:
        raise HTTPException(status_code=404, detail="Ingredient variation not found")
    _require_owned_base_ingredient(session, variation.base_ingredient_id, household_id)
    return variation


def _base_payload(session: Session, item, counts: dict[str, int] | None = None) -> dict[str, object]:
    # Single-item callers (detail route) let this fall back to a per-row
    # count; the list route precomputes them in bulk and passes them in
    # to avoid the 4*N COUNT query storm (M62).
    if counts is None:
        counts = ingredient_counts(session, item.id)
    return {
        "base_ingredient_id": item.id,
        "name": item.name,
        "normalized_name": item.normalized_name,
        "category": item.category,
        "default_unit": item.default_unit,
        "notes": item.notes,
        "source_name": item.source_name,
        "source_record_id": item.source_record_id,
        "source_url": item.source_url,
        "provisional": item.provisional,
        "active": item.active,
        "nutrition_reference_amount": item.nutrition_reference_amount,
        "nutrition_reference_unit": item.nutrition_reference_unit,
        "calories": item.calories,
        "archived_at": item.archived_at,
        "merged_into_id": item.merged_into_id,
        # M25: catalog ownership + lifecycle.
        "household_id": item.household_id,
        "submission_status": item.submission_status,
        **counts,
        "product_like": is_product_like_base_ingredient(item),
        "updated_at": item.updated_at,
    }


def _variation_payload(item) -> dict[str, object]:
    return {
        "ingredient_variation_id": item.id,
        "base_ingredient_id": item.base_ingredient_id,
        "name": item.name,
        "normalized_name": item.normalized_name,
        "brand": item.brand,
        "upc": item.upc,
        "package_size_amount": item.package_size_amount,
        "package_size_unit": item.package_size_unit,
        "count_per_package": item.count_per_package,
        "product_url": item.product_url,
        "retailer_hint": item.retailer_hint,
        "notes": item.notes,
        "source_name": item.source_name,
        "source_record_id": item.source_record_id,
        "source_url": item.source_url,
        "active": item.active,
        "nutrition_reference_amount": item.nutrition_reference_amount,
        "nutrition_reference_unit": item.nutrition_reference_unit,
        "calories": item.calories,
        "archived_at": item.archived_at,
        "merged_into_id": item.merged_into_id,
        "updated_at": item.updated_at,
    }


def _preference_payload(item) -> dict[str, object]:
    return {
        "preference_id": item.id,
        "base_ingredient_id": item.base_ingredient_id,
        "base_ingredient_name": item.base_ingredient.name,
        "preferred_variation_id": item.preferred_variation_id,
        "preferred_variation_name": item.preferred_variation.name if item.preferred_variation is not None else None,
        "preferred_brand": item.preferred_brand,
        "choice_mode": item.choice_mode,
        "active": item.active,
        "notes": item.notes,
        "rank": item.rank,
        "updated_at": item.updated_at,
    }


@router.get("", response_model=list[BaseIngredientOut])
def list_ingredients_route(
    q: str = "",
    limit: int = Query(default=20, ge=1, le=200),
    include_archived: bool = False,
    provisional_only: bool = False,
    with_preferences: bool = False,
    with_variations: bool = False,
    include_product_like: bool = False,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    items = search_base_ingredients(
        session,
        q,
        limit=limit,
        include_archived=include_archived,
        provisional_only=provisional_only,
        with_preferences=with_preferences,
        with_variations=with_variations,
        include_product_like=include_product_like,
        household_id=current_user.household_id,
    )
    counts_map = ingredient_counts_bulk(session, [item.id for item in items])
    return [_base_payload(session, item, counts_map.get(item.id)) for item in items]


@router.get("/{base_ingredient_id}", response_model=BaseIngredientDetailOut)
def ingredient_detail_route(
    base_ingredient_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    item = _require_visible_base_ingredient(session, base_ingredient_id, current_user.household_id)
    preference = ingredient_preference_for_base(session, current_user.id, item.id)
    return {
        "ingredient": _base_payload(session, item),
        "variations": [_variation_payload(variation) for variation in list_variations(session, item.id)],
        "preference": _preference_payload(preference) if preference is not None else None,
        "usage": ingredient_usage_summary(session, item.id).as_payload(),
    }


@router.post("", response_model=BaseIngredientOut)
def create_ingredient_route(
    payload: BaseIngredientPayload,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    # M25: new ingredients default to household_only — author-private
    # until they choose to submit for global adoption. Edits to an
    # existing row preserve its current ownership/status (no cross-
    # household tampering since the GET filter prevents seeing rows
    # the household doesn't own anyway).
    submission_status = payload.submission_status or "household_only"
    household_id = current_user.household_id if submission_status != "approved" else None
    if payload.base_ingredient_id:
        _require_owned_base_ingredient(session, payload.base_ingredient_id, current_user.household_id)
        try:
            item = update_base_ingredient(
                session,
                base_ingredient_id=payload.base_ingredient_id,
                name=payload.name,
                normalized_name=payload.normalized_name,
                category=payload.category,
                default_unit=payload.default_unit,
                notes=payload.notes,
                source_name=payload.source_name,
                source_record_id=payload.source_record_id,
                source_url=payload.source_url,
                provisional=payload.provisional,
                active=payload.active,
                nutrition_reference_amount=payload.nutrition_reference_amount,
                nutrition_reference_unit=payload.nutrition_reference_unit,
                calories=payload.calories,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    else:
        item = ensure_base_ingredient(
            session,
            name=payload.name,
            normalized_name=payload.normalized_name,
            category=payload.category,
            default_unit=payload.default_unit,
            notes=payload.notes,
            source_name=payload.source_name,
            source_record_id=payload.source_record_id,
            source_url=payload.source_url,
            provisional=payload.provisional,
            active=payload.active,
            nutrition_reference_amount=payload.nutrition_reference_amount,
            nutrition_reference_unit=payload.nutrition_reference_unit,
            calories=payload.calories,
            household_id=household_id,
            submission_status=submission_status,
        )
    session.commit()
    return _base_payload(session, item)


@router.post("/{base_ingredient_id}/submit", response_model=BaseIngredientOut)
def submit_ingredient_for_adoption_route(
    base_ingredient_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Author household promotes a `household_only` row to `submitted`
    so an admin can review for global adoption."""
    from app.services.ingredient_catalog.governance import submit_for_adoption

    try:
        item = submit_for_adoption(
            session,
            ingredient_id=base_ingredient_id,
            household_id=current_user.household_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return _base_payload(session, item)


@router.post("/{base_ingredient_id}/approve", response_model=BaseIngredientOut)
def approve_ingredient_route(
    base_ingredient_id: str,
    session: Session = Depends(get_session),
    _: None = Depends(require_admin_bearer),
) -> dict[str, object]:
    """Admin promotes a submitted (or household_only) row to approved
    and clears the household scope. The row joins the global catalog.
    Bearer-token gated via `SIMMERSMITH_API_TOKEN`.
    """
    from app.services.ingredient_catalog.governance import approve_submission

    try:
        item = approve_submission(session, ingredient_id=base_ingredient_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return _base_payload(session, item)


@router.post("/{base_ingredient_id}/reject", response_model=BaseIngredientOut)
def reject_ingredient_route(
    base_ingredient_id: str,
    session: Session = Depends(get_session),
    reason: str = "",
    _: None = Depends(require_admin_bearer),
) -> dict[str, object]:
    """Admin declines a submitted row; stays visible to the authoring
    household for context. Bearer-token gated."""
    from app.services.ingredient_catalog.governance import reject_submission

    try:
        item = reject_submission(
            session, ingredient_id=base_ingredient_id, reason=reason
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return _base_payload(session, item)


@router.post("/{base_ingredient_id}/archive", response_model=BaseIngredientOut)
def archive_ingredient_route(
    base_ingredient_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    _require_owned_base_ingredient(session, base_ingredient_id, current_user.household_id)
    try:
        item = archive_base_ingredient(session, base_ingredient_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return _base_payload(session, item)


@router.post("/{base_ingredient_id}/merge", response_model=BaseIngredientOut)
def merge_ingredient_route(
    base_ingredient_id: str,
    payload: IngredientMergeRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    # Both ends of the merge must belong to the caller's household.
    _require_owned_base_ingredient(session, base_ingredient_id, current_user.household_id)
    _require_owned_base_ingredient(session, payload.target_id, current_user.household_id)
    try:
        item = merge_base_ingredients(session, source_id=base_ingredient_id, target_id=payload.target_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return _base_payload(session, item)


@router.get("/{base_ingredient_id}/variations", response_model=list[IngredientVariationOut])
def list_variations_route(
    base_ingredient_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    # Was missing get_current_user entirely — any caller could enumerate any
    # household's private variations by base id. Gate on read-visibility.
    _require_visible_base_ingredient(session, base_ingredient_id, current_user.household_id)
    return [_variation_payload(item) for item in list_variations(session, base_ingredient_id)]


@router.post("/{base_ingredient_id}/variations", response_model=IngredientVariationOut)
def create_variation_route(
    base_ingredient_id: str,
    payload: IngredientVariationPayload,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    _require_owned_base_ingredient(session, base_ingredient_id, current_user.household_id)
    try:
        if payload.ingredient_variation_id:
            item = update_variation(
                session,
                ingredient_variation_id=payload.ingredient_variation_id,
                base_ingredient_id=base_ingredient_id,
                name=payload.name,
                normalized_name=payload.normalized_name,
                brand=payload.brand,
                upc=payload.upc,
                package_size_amount=payload.package_size_amount,
                package_size_unit=payload.package_size_unit,
                count_per_package=payload.count_per_package,
                product_url=payload.product_url,
                retailer_hint=payload.retailer_hint,
                notes=payload.notes,
                source_name=payload.source_name,
                source_record_id=payload.source_record_id,
                source_url=payload.source_url,
                active=payload.active,
                nutrition_reference_amount=payload.nutrition_reference_amount,
                nutrition_reference_unit=payload.nutrition_reference_unit,
                calories=payload.calories,
            )
        else:
            item = create_or_update_variation(
                session,
                base_ingredient_id=base_ingredient_id,
                variation_id=payload.ingredient_variation_id,
                name=payload.name,
                normalized_name=payload.normalized_name,
                brand=payload.brand,
                upc=payload.upc,
                package_size_amount=payload.package_size_amount,
                package_size_unit=payload.package_size_unit,
                count_per_package=payload.count_per_package,
                product_url=payload.product_url,
                retailer_hint=payload.retailer_hint,
                notes=payload.notes,
                source_name=payload.source_name,
                source_record_id=payload.source_record_id,
                source_url=payload.source_url,
                active=payload.active,
                nutrition_reference_amount=payload.nutrition_reference_amount,
                nutrition_reference_unit=payload.nutrition_reference_unit,
                calories=payload.calories,
            )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return _variation_payload(item)


@router.post("/variations/{ingredient_variation_id}/archive", response_model=IngredientVariationOut)
def archive_variation_route(
    ingredient_variation_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    _require_owned_variation(session, ingredient_variation_id, current_user.household_id)
    try:
        item = archive_variation(session, ingredient_variation_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return _variation_payload(item)


@router.post("/variations/{ingredient_variation_id}/merge", response_model=IngredientVariationOut)
def merge_variation_route(
    ingredient_variation_id: str,
    payload: IngredientMergeRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    # Both variations must belong to the caller's household (via their base).
    _require_owned_variation(session, ingredient_variation_id, current_user.household_id)
    _require_owned_variation(session, payload.target_id, current_user.household_id)
    try:
        item = merge_variations(session, source_id=ingredient_variation_id, target_id=payload.target_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return _variation_payload(item)


@router.post("/resolve", response_model=IngredientResolveOut)
def resolve_ingredient_route(
    payload: IngredientResolveRequest,
    session: Session = Depends(get_session),
) -> dict[str, object]:
    return resolve_ingredient(
        session,
        ingredient_name=payload.ingredient_name,
        normalized_name=payload.normalized_name,
        quantity=payload.quantity,
        unit=payload.unit,
        prep=payload.prep,
        category=payload.category,
        notes=payload.notes,
    ).as_payload()


@preferences_router.get("", response_model=list[IngredientPreferenceOut])
def list_ingredient_preferences_route(session: Session = Depends(get_session), current_user: CurrentUser = Depends(get_current_user)) -> list[dict[str, object]]:
    return [_preference_payload(item) for item in list_ingredient_preferences(session, current_user.id)]


@preferences_router.post("", response_model=IngredientPreferenceOut)
def upsert_ingredient_preference_route(
    payload: IngredientPreferencePayload,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    try:
        item = upsert_ingredient_preference(
            session,
            current_user.id,
            base_ingredient_id=payload.base_ingredient_id,
            preferred_variation_id=payload.preferred_variation_id,
            preferred_brand=payload.preferred_brand,
            choice_mode=payload.choice_mode,
            active=payload.active,
            notes=payload.notes,
            rank=payload.rank,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(item)
    return _preference_payload(item)
