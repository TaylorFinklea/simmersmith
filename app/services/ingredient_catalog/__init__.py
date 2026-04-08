from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import (
    BaseIngredient,
    GroceryItem,
    IngredientVariation,
    NutritionItem,
    RecipeIngredient,
    WeekMealIngredient,
)

from .product_rewrite import (
    _variation_candidate_from_base,
    apply_product_like_base_rewrites,
    cleaned_base_ingredient_name,
    is_product_like_base_ingredient,
    normalize_product_like_base_ingredients,
    plan_product_like_base_rewrites,
)
from .search import ingredient_counts, ingredient_usage_summary, search_base_ingredients
from .shared import (
    IngredientResolution,
    IngredientUsageSummary,
    ProductLikeRewritePlan,
    ProductLikeRewriteResult,
    RESOLUTION_STATUSES,
    VariationCandidate,
    _active_base_by_normalized_name,
    _source_payload,
    get_base_ingredient,
    normalize_name,
    normalize_unit,
)
from .variation import (
    archive_base_ingredient,
    archive_variation,
    choice_for_base_ingredient,
    create_or_update_variation,
    ensure_base_ingredient,
    ingredient_preference_for_base,
    list_ingredient_preferences,
    list_variations,
    merge_base_ingredients,
    merge_variations,
    update_base_ingredient,
    update_variation,
    upsert_ingredient_preference,
)


def resolve_ingredient(
    session: Session,
    *,
    ingredient_name: str,
    normalized_name: str | None = None,
    quantity: float | None = None,
    unit: str = "",
    prep: str = "",
    category: str = "",
    notes: str = "",
    base_ingredient_id: str | None = None,
    ingredient_variation_id: str | None = None,
    resolution_status: str | None = None,
) -> IngredientResolution:
    cleaned_name = str(ingredient_name).strip()
    normalized = normalize_name(normalized_name or cleaned_name)
    generic_name = cleaned_base_ingredient_name(cleaned_name) or cleaned_name
    generic_normalized = normalize_name(generic_name)
    cleaned_unit = normalize_unit(unit)
    cleaned_category = str(category or "").strip()
    cleaned_notes = str(notes or "").strip()
    cleaned_prep = str(prep or "").strip()

    variation = None
    base = None
    locked = resolution_status == "locked"
    inferred_variation = False
    if ingredient_variation_id:
        variation = session.get(IngredientVariation, ingredient_variation_id)
        if variation is not None and variation.archived_at is None and variation.active:
            base = variation.base_ingredient
            locked = locked or True
    if base is None and base_ingredient_id:
        base = session.get(BaseIngredient, base_ingredient_id)
        if base is not None and (base.archived_at is not None or not base.active):
            base = None

    if variation is None and normalized:
        variation = session.scalar(
            select(IngredientVariation).where(
                IngredientVariation.normalized_name == normalized,
                IngredientVariation.archived_at.is_(None),
                IngredientVariation.active.is_(True),
            )
        )
        if variation is not None:
            base = variation.base_ingredient
            inferred_variation = True

    if base is None and normalized:
        candidate = _active_base_by_normalized_name(session, normalized)
        if candidate is not None and is_product_like_base_ingredient(candidate):
            generic_name = (
                cleaned_base_ingredient_name(
                    candidate.name,
                    source_name=candidate.source_name,
                    source_payload=_source_payload(candidate),
                )
                or generic_name
            )
            generic_normalized = normalize_name(generic_name) or generic_normalized
            base = _active_base_by_normalized_name(session, generic_normalized)
            if base is None:
                base = ensure_base_ingredient(
                    session,
                    name=generic_name,
                    normalized_name=generic_normalized,
                    category=candidate.category or cleaned_category,
                    default_unit=candidate.default_unit or cleaned_unit,
                    notes=candidate.notes or cleaned_notes,
                    provisional=candidate.provisional,
                    active=True,
                    nutrition_reference_amount=candidate.nutrition_reference_amount,
                    nutrition_reference_unit=candidate.nutrition_reference_unit,
                    calories=candidate.calories,
                )
            candidate_variation = _variation_candidate_from_base(candidate)
            if candidate_variation is not None:
                variation = create_or_update_variation(
                    session,
                    base_ingredient_id=base.id,
                    name=candidate_variation.name,
                    normalized_name=candidate_variation.normalized_name,
                    brand=candidate_variation.brand,
                    upc=candidate_variation.upc,
                    package_size_amount=candidate_variation.package_size_amount,
                    package_size_unit=candidate_variation.package_size_unit,
                    count_per_package=candidate_variation.count_per_package,
                    product_url=candidate_variation.product_url,
                    retailer_hint=candidate_variation.retailer_hint,
                    notes=candidate_variation.notes,
                    source_name=candidate_variation.source_name,
                    source_record_id=candidate_variation.source_record_id,
                    source_url=candidate_variation.source_url,
                    source_payload=candidate_variation.source_payload,
                    active=True,
                    nutrition_reference_amount=candidate_variation.nutrition_reference_amount,
                    nutrition_reference_unit=candidate_variation.nutrition_reference_unit,
                    calories=candidate_variation.calories,
                )
                inferred_variation = True
        elif candidate is not None:
            base = candidate

    if base is None and generic_normalized:
        base = _active_base_by_normalized_name(session, generic_normalized)

    if base is None and generic_normalized:
        nutrition_item = session.scalar(
            select(NutritionItem).where(NutritionItem.normalized_name == generic_normalized)
        )
        if nutrition_item is not None:
            base = ensure_base_ingredient(
                session,
                name=nutrition_item.name,
                normalized_name=nutrition_item.normalized_name,
                category=cleaned_category,
                default_unit=cleaned_unit,
                notes=cleaned_notes,
                nutrition_reference_amount=nutrition_item.reference_amount,
                nutrition_reference_unit=nutrition_item.reference_unit,
                calories=nutrition_item.calories,
            )

    if base is None and generic_normalized:
        base = ensure_base_ingredient(
            session,
            name=generic_name,
            normalized_name=generic_normalized,
            category=cleaned_category,
            default_unit=cleaned_unit,
            notes=cleaned_notes,
            provisional=True,
        )

    if resolution_status in RESOLUTION_STATUSES:
        final_status = resolution_status
    elif locked and variation is not None:
        final_status = "locked"
    elif inferred_variation and variation is not None:
        final_status = "suggested"
    elif variation is not None or base is not None:
        final_status = "resolved"
    else:
        final_status = "unresolved"

    return IngredientResolution(
        ingredient_name=cleaned_name,
        normalized_name=normalized,
        quantity=quantity,
        unit=cleaned_unit,
        prep=cleaned_prep,
        category=cleaned_category,
        notes=cleaned_notes,
        base_ingredient_id=base.id if base is not None else None,
        base_ingredient_name=base.name if base is not None else None,
        ingredient_variation_id=variation.id if variation is not None else None,
        ingredient_variation_name=variation.name if variation is not None else None,
        resolution_status=final_status,
    )


def resolve_ingredient_payloads(
    session: Session,
    ingredients: list[dict[str, Any]],
) -> list[dict[str, object]]:
    return [
        {
            **ingredient,
            **resolve_ingredient(
                session,
                ingredient_name=str(ingredient.get("ingredient_name") or ""),
                normalized_name=str(ingredient.get("normalized_name") or "") or None,
                quantity=ingredient.get("quantity"),
                unit=str(ingredient.get("unit") or ""),
                prep=str(ingredient.get("prep") or ""),
                category=str(ingredient.get("category") or ""),
                notes=str(ingredient.get("notes") or ""),
                base_ingredient_id=str(ingredient.get("base_ingredient_id") or "") or None,
                ingredient_variation_id=str(ingredient.get("ingredient_variation_id") or "")
                or None,
                resolution_status=str(ingredient.get("resolution_status") or "") or None,
            ).as_payload(),
        }
        for ingredient in ingredients
        if str(ingredient.get("ingredient_name") or "").strip()
    ]


def ensure_catalog_defaults(session: Session) -> None:
    nutrition_items = session.scalars(select(NutritionItem).order_by(NutritionItem.name)).all()
    for item in nutrition_items:
        ensure_base_ingredient(
            session,
            name=item.name,
            normalized_name=item.normalized_name,
            default_unit=item.reference_unit,
            nutrition_reference_amount=item.reference_amount,
            nutrition_reference_unit=item.reference_unit,
            calories=item.calories,
            notes=item.notes,
        )

    seen_names = set(session.scalars(select(BaseIngredient.normalized_name)).all())
    for row in list(session.scalars(select(RecipeIngredient)).all()) + list(
        session.scalars(select(WeekMealIngredient)).all()
    ):
        normalized = normalize_name(row.normalized_name or row.ingredient_name)
        if not normalized or normalized in seen_names:
            continue
        ensure_base_ingredient(
            session,
            name=row.ingredient_name,
            normalized_name=normalized,
            category=row.category,
            default_unit=row.unit,
            notes=row.notes,
        )
        seen_names.add(normalized)

    def _backfill_rows(rows: list[RecipeIngredient | WeekMealIngredient | GroceryItem]) -> None:
        for row in rows:
            if row.base_ingredient_id:
                continue
            resolution = resolve_ingredient(
                session,
                ingredient_name=row.ingredient_name,
                normalized_name=row.normalized_name,
                quantity=getattr(row, "quantity", None)
                if hasattr(row, "quantity")
                else getattr(row, "total_quantity", None),
                unit=row.unit,
                prep=getattr(row, "prep", ""),
                category=row.category,
                notes=row.notes,
            )
            row.base_ingredient_id = resolution.base_ingredient_id
            row.ingredient_variation_id = resolution.ingredient_variation_id
            row.resolution_status = resolution.resolution_status

    _backfill_rows(list(session.scalars(select(RecipeIngredient)).all()))
    _backfill_rows(list(session.scalars(select(WeekMealIngredient)).all()))
    _backfill_rows(list(session.scalars(select(GroceryItem)).all()))
    session.flush()


__all__ = [
    "IngredientResolution",
    "IngredientUsageSummary",
    "ProductLikeRewritePlan",
    "ProductLikeRewriteResult",
    "VariationCandidate",
    "apply_product_like_base_rewrites",
    "archive_base_ingredient",
    "archive_variation",
    "choice_for_base_ingredient",
    "cleaned_base_ingredient_name",
    "create_or_update_variation",
    "ensure_base_ingredient",
    "ensure_catalog_defaults",
    "get_base_ingredient",
    "ingredient_counts",
    "ingredient_preference_for_base",
    "ingredient_usage_summary",
    "is_product_like_base_ingredient",
    "list_ingredient_preferences",
    "list_variations",
    "merge_base_ingredients",
    "merge_variations",
    "normalize_name",
    "normalize_product_like_base_ingredients",
    "normalize_unit",
    "plan_product_like_base_rewrites",
    "resolve_ingredient",
    "resolve_ingredient_payloads",
    "search_base_ingredients",
    "update_base_ingredient",
    "update_variation",
    "upsert_ingredient_preference",
]
