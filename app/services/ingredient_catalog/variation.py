from __future__ import annotations

import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import (
    BaseIngredient,
    GroceryItem,
    IngredientPreference,
    IngredientVariation,
    RecipeIngredient,
    WeekMealIngredient,
    utcnow,
)

from .shared import (
    _active_variation_by_normalized_name,
    _clean_category,
    _normalized_or_name,
    get_base_ingredient,
    normalize_unit,
)


def ensure_base_ingredient(
    session: Session,
    *,
    name: str,
    normalized_name: str | None = None,
    category: str = "",
    default_unit: str = "",
    notes: str = "",
    source_name: str = "",
    source_record_id: str = "",
    source_url: str = "",
    source_payload: dict[str, Any] | None = None,
    provisional: bool = False,
    active: bool = True,
    nutrition_reference_amount: float | None = None,
    nutrition_reference_unit: str = "",
    calories: float | None = None,
) -> BaseIngredient:
    cleaned_name = str(name).strip()
    normalized = _normalized_or_name(cleaned_name, normalized_name)
    existing = session.scalar(
        select(BaseIngredient).where(BaseIngredient.normalized_name == normalized)
    )
    if existing is None:
        existing = BaseIngredient(
            name=cleaned_name or normalized,
            normalized_name=normalized,
            category=_clean_category(category),
            default_unit=normalize_unit(default_unit),
            notes=str(notes or "").strip(),
            source_name=str(source_name or "").strip(),
            source_record_id=str(source_record_id or "").strip(),
            source_url=str(source_url or "").strip(),
            source_payload_json=json.dumps(source_payload or {}, sort_keys=True),
            provisional=provisional,
            active=active,
            nutrition_reference_amount=nutrition_reference_amount,
            nutrition_reference_unit=normalize_unit(nutrition_reference_unit),
            calories=calories,
        )
        session.add(existing)
    else:
        if cleaned_name:
            existing.name = cleaned_name
        if category and not existing.category:
            existing.category = _clean_category(category)
        if default_unit and not existing.default_unit:
            existing.default_unit = normalize_unit(default_unit)
        if notes and not existing.notes:
            existing.notes = str(notes).strip()
        if source_name and not existing.source_name:
            existing.source_name = str(source_name).strip()
        if source_record_id and not existing.source_record_id:
            existing.source_record_id = str(source_record_id).strip()
        if source_url and not existing.source_url:
            existing.source_url = str(source_url).strip()
        if source_payload and existing.source_payload_json in {"", "{}"}:
            existing.source_payload_json = json.dumps(source_payload, sort_keys=True)
        existing.provisional = existing.provisional and provisional
        existing.active = active or existing.active
        if existing.nutrition_reference_amount is None and nutrition_reference_amount is not None:
            existing.nutrition_reference_amount = nutrition_reference_amount
        if not existing.nutrition_reference_unit and nutrition_reference_unit:
            existing.nutrition_reference_unit = normalize_unit(nutrition_reference_unit)
        if existing.calories is None and calories is not None:
            existing.calories = calories
        existing.updated_at = utcnow()
    session.flush()
    return existing


def list_variations(session: Session, base_ingredient_id: str) -> list[IngredientVariation]:
    statement = (
        select(IngredientVariation)
        .where(
            IngredientVariation.base_ingredient_id == base_ingredient_id,
            IngredientVariation.archived_at.is_(None),
            IngredientVariation.active.is_(True),
        )
        .order_by(IngredientVariation.name)
    )
    return list(session.scalars(statement).all())


def create_or_update_variation(
    session: Session,
    *,
    base_ingredient_id: str,
    variation_id: str | None = None,
    name: str,
    normalized_name: str | None = None,
    brand: str = "",
    upc: str = "",
    package_size_amount: float | None = None,
    package_size_unit: str = "",
    count_per_package: float | None = None,
    product_url: str = "",
    retailer_hint: str = "",
    notes: str = "",
    source_name: str = "",
    source_record_id: str = "",
    source_url: str = "",
    source_payload: dict[str, Any] | None = None,
    active: bool = True,
    nutrition_reference_amount: float | None = None,
    nutrition_reference_unit: str = "",
    calories: float | None = None,
) -> IngredientVariation:
    base = get_base_ingredient(session, base_ingredient_id)
    if base is None:
        raise ValueError("Base ingredient not found")
    cleaned_name = str(name).strip()
    normalized = _normalized_or_name(cleaned_name, normalized_name)
    variation = None
    if variation_id:
        variation = session.get(IngredientVariation, variation_id)
        if variation is None:
            raise ValueError("Ingredient variation not found")
    if variation is None:
        variation = session.scalar(
            select(IngredientVariation).where(
                IngredientVariation.base_ingredient_id == base_ingredient_id,
                IngredientVariation.normalized_name == normalized,
            )
        )
    if variation is None:
        variation = IngredientVariation(
            base_ingredient_id=base_ingredient_id,
            name=cleaned_name or normalized,
            normalized_name=normalized,
            brand=str(brand or "").strip(),
            upc=str(upc or "").strip(),
            package_size_amount=package_size_amount,
            package_size_unit=normalize_unit(package_size_unit),
            count_per_package=count_per_package,
            product_url=str(product_url or "").strip(),
            retailer_hint=str(retailer_hint or "").strip(),
            notes=str(notes or "").strip(),
            source_name=str(source_name or "").strip(),
            source_record_id=str(source_record_id or "").strip(),
            source_url=str(source_url or "").strip(),
            source_payload_json=json.dumps(source_payload or {}, sort_keys=True),
            active=active,
            nutrition_reference_amount=nutrition_reference_amount,
            nutrition_reference_unit=normalize_unit(nutrition_reference_unit),
            calories=calories,
        )
        session.add(variation)
    else:
        variation.base_ingredient_id = base_ingredient_id
        variation.name = cleaned_name or variation.name
        variation.normalized_name = normalized
        variation.brand = str(brand or "").strip()
        variation.upc = str(upc or "").strip()
        variation.package_size_amount = package_size_amount
        variation.package_size_unit = normalize_unit(package_size_unit)
        variation.count_per_package = count_per_package
        variation.product_url = str(product_url or "").strip()
        variation.retailer_hint = str(retailer_hint or "").strip()
        variation.notes = str(notes or "").strip()
        if source_name and not variation.source_name:
            variation.source_name = str(source_name).strip()
        if source_record_id and not variation.source_record_id:
            variation.source_record_id = str(source_record_id).strip()
        if source_url and not variation.source_url:
            variation.source_url = str(source_url).strip()
        if source_payload and variation.source_payload_json in {"", "{}"}:
            variation.source_payload_json = json.dumps(source_payload, sort_keys=True)
        variation.active = active or variation.active
        variation.nutrition_reference_amount = nutrition_reference_amount
        variation.nutrition_reference_unit = normalize_unit(nutrition_reference_unit)
        variation.calories = calories
        variation.updated_at = utcnow()
    session.flush()
    return variation


def upsert_ingredient_preference(
    session: Session,
    *,
    base_ingredient_id: str,
    preferred_variation_id: str | None = None,
    preferred_brand: str = "",
    choice_mode: str = "preferred",
    active: bool = True,
    notes: str = "",
) -> IngredientPreference:
    if choice_mode not in {"preferred", "cheapest", "best_reviewed", "rotate", "no_preference"}:
        raise ValueError("Unsupported choice mode")
    base = get_base_ingredient(session, base_ingredient_id)
    if base is None:
        raise ValueError("Base ingredient not found")
    if preferred_variation_id:
        variation = session.get(IngredientVariation, preferred_variation_id)
        if variation is None or variation.base_ingredient_id != base_ingredient_id:
            raise ValueError("Preferred variation not found for base ingredient")
    preference = session.scalar(
        select(IngredientPreference).where(
            IngredientPreference.base_ingredient_id == base_ingredient_id
        )
    )
    if preference is None:
        preference = IngredientPreference(
            base_ingredient_id=base_ingredient_id,
            preferred_variation_id=preferred_variation_id,
            preferred_brand=str(preferred_brand or "").strip(),
            choice_mode=choice_mode,
            active=active,
            notes=str(notes or "").strip(),
        )
        session.add(preference)
    else:
        preference.preferred_variation_id = preferred_variation_id
        preference.preferred_brand = str(preferred_brand or "").strip()
        preference.choice_mode = choice_mode
        preference.active = active
        preference.notes = str(notes or "").strip()
        preference.updated_at = utcnow()
    session.flush()
    return preference


def list_ingredient_preferences(session: Session) -> list[IngredientPreference]:
    statement = select(IngredientPreference).order_by(IngredientPreference.created_at)
    return list(session.scalars(statement).all())


def ingredient_preference_for_base(
    session: Session, base_ingredient_id: str
) -> IngredientPreference | None:
    return session.scalar(
        select(IngredientPreference).where(
            IngredientPreference.base_ingredient_id == base_ingredient_id
        )
    )


def update_base_ingredient(
    session: Session,
    *,
    base_ingredient_id: str,
    name: str,
    normalized_name: str | None = None,
    category: str = "",
    default_unit: str = "",
    notes: str = "",
    source_name: str = "",
    source_record_id: str = "",
    source_url: str = "",
    provisional: bool = False,
    active: bool = True,
    nutrition_reference_amount: float | None = None,
    nutrition_reference_unit: str = "",
    calories: float | None = None,
) -> BaseIngredient:
    item = get_base_ingredient(session, base_ingredient_id)
    if item is None:
        raise ValueError("Base ingredient not found")
    item.name = str(name).strip() or item.name
    item.normalized_name = _normalized_or_name(item.name, normalized_name)
    item.category = _clean_category(category)
    item.default_unit = normalize_unit(default_unit)
    item.notes = str(notes or "").strip()
    item.source_name = str(source_name or "").strip()
    item.source_record_id = str(source_record_id or "").strip()
    item.source_url = str(source_url or "").strip()
    item.provisional = provisional
    item.active = active
    item.nutrition_reference_amount = nutrition_reference_amount
    item.nutrition_reference_unit = normalize_unit(nutrition_reference_unit)
    item.calories = calories
    item.updated_at = utcnow()
    session.flush()
    return item


def archive_base_ingredient(session: Session, base_ingredient_id: str) -> BaseIngredient:
    item = get_base_ingredient(session, base_ingredient_id)
    if item is None:
        raise ValueError("Base ingredient not found")
    item.active = False
    item.archived_at = utcnow()
    item.updated_at = utcnow()
    session.flush()
    return item


def merge_base_ingredients(session: Session, *, source_id: str, target_id: str) -> BaseIngredient:
    if source_id == target_id:
        raise ValueError("Source and target ingredient must differ")
    source = get_base_ingredient(session, source_id)
    target = get_base_ingredient(session, target_id)
    if source is None or target is None:
        raise ValueError("Base ingredient not found")
    for row in session.scalars(
        select(RecipeIngredient).where(RecipeIngredient.base_ingredient_id == source.id)
    ).all():
        row.base_ingredient_id = target.id
        if row.resolution_status == "unresolved":
            row.resolution_status = "resolved"
    for row in session.scalars(
        select(WeekMealIngredient).where(WeekMealIngredient.base_ingredient_id == source.id)
    ).all():
        row.base_ingredient_id = target.id
        if row.resolution_status == "unresolved":
            row.resolution_status = "resolved"
    for row in session.scalars(
        select(GroceryItem).where(GroceryItem.base_ingredient_id == source.id)
    ).all():
        row.base_ingredient_id = target.id
        if row.resolution_status == "unresolved":
            row.resolution_status = "resolved"
    for row in session.scalars(
        select(IngredientVariation).where(IngredientVariation.base_ingredient_id == source.id)
    ).all():
        duplicate = _active_variation_by_normalized_name(
            session,
            base_ingredient_id=target.id,
            normalized_name=row.normalized_name,
        )
        if duplicate is not None and duplicate.id != row.id:
            merge_variations(session, source_id=row.id, target_id=duplicate.id)
            continue
        row.base_ingredient_id = target.id
    preference = ingredient_preference_for_base(session, source.id)
    if preference is not None:
        existing = ingredient_preference_for_base(session, target.id)
        if existing is None:
            preference.base_ingredient_id = target.id
        else:
            if not existing.preferred_variation_id and preference.preferred_variation_id:
                existing.preferred_variation_id = preference.preferred_variation_id
            if not existing.preferred_brand and preference.preferred_brand:
                existing.preferred_brand = preference.preferred_brand
            if not existing.notes and preference.notes:
                existing.notes = preference.notes
            session.delete(preference)
    source.active = False
    source.archived_at = utcnow()
    source.merged_into_id = target.id
    source.updated_at = utcnow()
    target.updated_at = utcnow()
    session.flush()
    return target


def update_variation(
    session: Session,
    *,
    ingredient_variation_id: str,
    base_ingredient_id: str,
    name: str,
    normalized_name: str | None = None,
    brand: str = "",
    upc: str = "",
    package_size_amount: float | None = None,
    package_size_unit: str = "",
    count_per_package: float | None = None,
    product_url: str = "",
    retailer_hint: str = "",
    notes: str = "",
    source_name: str = "",
    source_record_id: str = "",
    source_url: str = "",
    active: bool = True,
    nutrition_reference_amount: float | None = None,
    nutrition_reference_unit: str = "",
    calories: float | None = None,
) -> IngredientVariation:
    return create_or_update_variation(
        session,
        base_ingredient_id=base_ingredient_id,
        variation_id=ingredient_variation_id,
        name=name,
        normalized_name=normalized_name,
        brand=brand,
        upc=upc,
        package_size_amount=package_size_amount,
        package_size_unit=package_size_unit,
        count_per_package=count_per_package,
        product_url=product_url,
        retailer_hint=retailer_hint,
        notes=notes,
        source_name=source_name,
        source_record_id=source_record_id,
        source_url=source_url,
        active=active,
        nutrition_reference_amount=nutrition_reference_amount,
        nutrition_reference_unit=nutrition_reference_unit,
        calories=calories,
    )


def archive_variation(session: Session, ingredient_variation_id: str) -> IngredientVariation:
    item = session.get(IngredientVariation, ingredient_variation_id)
    if item is None:
        raise ValueError("Ingredient variation not found")
    item.active = False
    item.archived_at = utcnow()
    item.updated_at = utcnow()
    session.flush()
    return item


def merge_variations(session: Session, *, source_id: str, target_id: str) -> IngredientVariation:
    if source_id == target_id:
        raise ValueError("Source and target variation must differ")
    source = session.get(IngredientVariation, source_id)
    target = session.get(IngredientVariation, target_id)
    if source is None or target is None:
        raise ValueError("Ingredient variation not found")
    for row in session.scalars(
        select(RecipeIngredient).where(RecipeIngredient.ingredient_variation_id == source.id)
    ).all():
        row.ingredient_variation_id = target.id
        row.base_ingredient_id = target.base_ingredient_id
    for row in session.scalars(
        select(WeekMealIngredient).where(WeekMealIngredient.ingredient_variation_id == source.id)
    ).all():
        row.ingredient_variation_id = target.id
        row.base_ingredient_id = target.base_ingredient_id
    for row in session.scalars(
        select(GroceryItem).where(GroceryItem.ingredient_variation_id == source.id)
    ).all():
        row.ingredient_variation_id = target.id
        row.base_ingredient_id = target.base_ingredient_id
    for preference in session.scalars(
        select(IngredientPreference).where(IngredientPreference.preferred_variation_id == source.id)
    ).all():
        preference.preferred_variation_id = target.id
        preference.base_ingredient_id = target.base_ingredient_id
    source.active = False
    source.archived_at = utcnow()
    source.merged_into_id = target.id
    source.updated_at = utcnow()
    target.updated_at = utcnow()
    session.flush()
    return target


def choice_for_base_ingredient(
    session: Session,
    *,
    base_ingredient_id: str | None,
    recipe_variation_id: str | None,
    recipe_resolution_status: str,
) -> tuple[BaseIngredient | None, IngredientVariation | None, str]:
    base = session.get(BaseIngredient, base_ingredient_id) if base_ingredient_id else None
    recipe_variation = (
        session.get(IngredientVariation, recipe_variation_id) if recipe_variation_id else None
    )
    if base is not None and (base.archived_at is not None or not base.active):
        base = None
    if recipe_variation is not None and (
        recipe_variation.archived_at is not None or not recipe_variation.active
    ):
        recipe_variation = None
    if recipe_variation is not None:
        base = recipe_variation.base_ingredient
    if recipe_variation is not None and recipe_resolution_status == "locked":
        return base, recipe_variation, "locked"
    if base is None:
        return None, None, "unresolved"

    preference = session.scalar(
        select(IngredientPreference).where(
            IngredientPreference.base_ingredient_id == base.id,
            IngredientPreference.active.is_(True),
        )
    )
    if preference is not None:
        chosen_variation = None
        if preference.preferred_variation_id:
            chosen_variation = session.get(IngredientVariation, preference.preferred_variation_id)
        elif preference.preferred_brand:
            chosen_variation = session.scalar(
                select(IngredientVariation).where(
                    IngredientVariation.base_ingredient_id == base.id,
                    IngredientVariation.brand.ilike(preference.preferred_brand),
                )
            )
        if chosen_variation is not None:
            return base, chosen_variation, "resolved"

    if recipe_variation is not None:
        return base, recipe_variation, recipe_resolution_status or "resolved"
    return base, None, "resolved"
