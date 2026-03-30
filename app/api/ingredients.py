from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db import get_session
from app.schemas import (
    BaseIngredientOut,
    BaseIngredientPayload,
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
    list_ingredient_preferences,
    list_variations,
    resolve_ingredient,
    search_base_ingredients,
    upsert_ingredient_preference,
)


router = APIRouter(prefix="/api/ingredients", tags=["ingredients"])
preferences_router = APIRouter(prefix="/api/ingredient-preferences", tags=["ingredients"])


def _base_payload(item) -> dict[str, object]:
    return {
        "base_ingredient_id": item.id,
        "name": item.name,
        "normalized_name": item.normalized_name,
        "category": item.category,
        "default_unit": item.default_unit,
        "notes": item.notes,
        "nutrition_reference_amount": item.nutrition_reference_amount,
        "nutrition_reference_unit": item.nutrition_reference_unit,
        "calories": item.calories,
        "updated_at": item.updated_at,
    }


def _variation_payload(item) -> dict[str, object]:
    return {
        "ingredient_variation_id": item.id,
        "base_ingredient_id": item.base_ingredient_id,
        "name": item.name,
        "normalized_name": item.normalized_name,
        "brand": item.brand,
        "package_size_amount": item.package_size_amount,
        "package_size_unit": item.package_size_unit,
        "count_per_package": item.count_per_package,
        "product_url": item.product_url,
        "retailer_hint": item.retailer_hint,
        "notes": item.notes,
        "nutrition_reference_amount": item.nutrition_reference_amount,
        "nutrition_reference_unit": item.nutrition_reference_unit,
        "calories": item.calories,
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
        "updated_at": item.updated_at,
    }


@router.get("", response_model=list[BaseIngredientOut])
def list_ingredients_route(
    q: str = "",
    limit: int = 20,
    session: Session = Depends(get_session),
) -> list[dict[str, object]]:
    return [_base_payload(item) for item in search_base_ingredients(session, q, limit=limit)]


@router.get("/{base_ingredient_id}", response_model=BaseIngredientOut)
def ingredient_detail_route(
    base_ingredient_id: str,
    session: Session = Depends(get_session),
) -> dict[str, object]:
    item = get_base_ingredient(session, base_ingredient_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Base ingredient not found")
    return _base_payload(item)


@router.post("", response_model=BaseIngredientOut)
def create_ingredient_route(
    payload: BaseIngredientPayload,
    session: Session = Depends(get_session),
) -> dict[str, object]:
    item = ensure_base_ingredient(
        session,
        name=payload.name,
        normalized_name=payload.normalized_name,
        category=payload.category,
        default_unit=payload.default_unit,
        notes=payload.notes,
        nutrition_reference_amount=payload.nutrition_reference_amount,
        nutrition_reference_unit=payload.nutrition_reference_unit,
        calories=payload.calories,
    )
    session.commit()
    return _base_payload(item)


@router.get("/{base_ingredient_id}/variations", response_model=list[IngredientVariationOut])
def list_variations_route(
    base_ingredient_id: str,
    session: Session = Depends(get_session),
) -> list[dict[str, object]]:
    if get_base_ingredient(session, base_ingredient_id) is None:
        raise HTTPException(status_code=404, detail="Base ingredient not found")
    return [_variation_payload(item) for item in list_variations(session, base_ingredient_id)]


@router.post("/{base_ingredient_id}/variations", response_model=IngredientVariationOut)
def create_variation_route(
    base_ingredient_id: str,
    payload: IngredientVariationPayload,
    session: Session = Depends(get_session),
) -> dict[str, object]:
    try:
        item = create_or_update_variation(
            session,
            base_ingredient_id=base_ingredient_id,
            variation_id=payload.ingredient_variation_id,
            name=payload.name,
            normalized_name=payload.normalized_name,
            brand=payload.brand,
            package_size_amount=payload.package_size_amount,
            package_size_unit=payload.package_size_unit,
            count_per_package=payload.count_per_package,
            product_url=payload.product_url,
            retailer_hint=payload.retailer_hint,
            notes=payload.notes,
            nutrition_reference_amount=payload.nutrition_reference_amount,
            nutrition_reference_unit=payload.nutrition_reference_unit,
            calories=payload.calories,
        )
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
def list_ingredient_preferences_route(session: Session = Depends(get_session)) -> list[dict[str, object]]:
    return [_preference_payload(item) for item in list_ingredient_preferences(session)]


@preferences_router.post("", response_model=IngredientPreferenceOut)
def upsert_ingredient_preference_route(
    payload: IngredientPreferencePayload,
    session: Session = Depends(get_session),
) -> dict[str, object]:
    try:
        item = upsert_ingredient_preference(
            session,
            base_ingredient_id=payload.base_ingredient_id,
            preferred_variation_id=payload.preferred_variation_id,
            preferred_brand=payload.preferred_brand,
            choice_mode=payload.choice_mode,
            active=payload.active,
            notes=payload.notes,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(item)
    return _preference_payload(item)
