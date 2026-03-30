from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import (
    BaseIngredient,
    GroceryItem,
    IngredientPreference,
    IngredientVariation,
    NutritionItem,
    RecipeIngredient,
    WeekMealIngredient,
    utcnow,
)


UNIT_MAP = {
    "count": "ct",
    "counts": "ct",
    "ct": "ct",
    "each": "ea",
    "ea": "ea",
    "egg": "ea",
    "eggs": "ea",
    "pound": "lb",
    "pounds": "lb",
    "lb": "lb",
    "lbs": "lb",
    "ounce": "oz",
    "ounces": "oz",
    "oz": "oz",
    "fluid ounce": "fl oz",
    "fluid ounces": "fl oz",
    "fl oz": "fl oz",
    "gallon": "gal",
    "gallons": "gal",
    "gal": "gal",
    "cup": "cup",
    "cups": "cup",
    "tablespoon": "tbsp",
    "tablespoons": "tbsp",
    "tbsp": "tbsp",
    "teaspoon": "tsp",
    "teaspoons": "tsp",
    "tsp": "tsp",
    "package": "pkg",
    "packages": "pkg",
    "pkg": "pkg",
    "can": "can",
    "cans": "can",
    "bag": "bag",
    "bags": "bag",
    "bunch": "bunch",
    "bunches": "bunch",
    "clove": "clove",
    "cloves": "clove",
    "slice": "slice",
    "slices": "slice",
}


def normalize_name(value: str) -> str:
    import re

    cleaned = value.lower().strip()
    cleaned = cleaned.replace("&", " and ")
    cleaned = re.sub(r"[^a-z0-9\s]", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def normalize_unit(value: object) -> str:
    text = normalize_name(str(value or ""))
    return UNIT_MAP.get(text, text)


RESOLUTION_STATUSES = {"unresolved", "suggested", "resolved", "locked"}


@dataclass(frozen=True)
class IngredientResolution:
    ingredient_name: str
    normalized_name: str
    quantity: float | None
    unit: str
    prep: str
    category: str
    notes: str
    base_ingredient_id: str | None
    base_ingredient_name: str | None
    ingredient_variation_id: str | None
    ingredient_variation_name: str | None
    resolution_status: str

    def as_payload(self) -> dict[str, object]:
        return {
            "ingredient_name": self.ingredient_name,
            "normalized_name": self.normalized_name,
            "quantity": self.quantity,
            "unit": self.unit,
            "prep": self.prep,
            "category": self.category,
            "notes": self.notes,
            "base_ingredient_id": self.base_ingredient_id,
            "base_ingredient_name": self.base_ingredient_name,
            "ingredient_variation_id": self.ingredient_variation_id,
            "ingredient_variation_name": self.ingredient_variation_name,
            "resolution_status": self.resolution_status,
        }


def _clean_category(category: str) -> str:
    return str(category or "").strip()


def _normalized_or_name(name: str, normalized_name: str | None = None) -> str:
    return normalize_name(normalized_name or name)


def search_base_ingredients(session: Session, query: str = "", limit: int = 20) -> list[BaseIngredient]:
    statement = select(BaseIngredient).order_by(BaseIngredient.name).limit(max(1, min(limit, 50)))
    normalized_query = normalize_name(query)
    if normalized_query:
        like_value = f"%{normalized_query}%"
        statement = (
            select(BaseIngredient)
            .where(BaseIngredient.normalized_name.like(like_value))
            .order_by(BaseIngredient.name)
            .limit(max(1, min(limit, 50)))
        )
    return list(session.scalars(statement).all())


def get_base_ingredient(session: Session, base_ingredient_id: str) -> BaseIngredient | None:
    return session.get(BaseIngredient, base_ingredient_id)


def ensure_base_ingredient(
    session: Session,
    *,
    name: str,
    normalized_name: str | None = None,
    category: str = "",
    default_unit: str = "",
    notes: str = "",
    nutrition_reference_amount: float | None = None,
    nutrition_reference_unit: str = "",
    calories: float | None = None,
) -> BaseIngredient:
    cleaned_name = str(name).strip()
    normalized = _normalized_or_name(cleaned_name, normalized_name)
    existing = session.scalar(select(BaseIngredient).where(BaseIngredient.normalized_name == normalized))
    if existing is None:
        existing = BaseIngredient(
            name=cleaned_name or normalized,
            normalized_name=normalized,
            category=_clean_category(category),
            default_unit=normalize_unit(default_unit),
            notes=str(notes or "").strip(),
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
        .where(IngredientVariation.base_ingredient_id == base_ingredient_id)
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
    package_size_amount: float | None = None,
    package_size_unit: str = "",
    count_per_package: float | None = None,
    product_url: str = "",
    retailer_hint: str = "",
    notes: str = "",
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
            package_size_amount=package_size_amount,
            package_size_unit=normalize_unit(package_size_unit),
            count_per_package=count_per_package,
            product_url=str(product_url or "").strip(),
            retailer_hint=str(retailer_hint or "").strip(),
            notes=str(notes or "").strip(),
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
        variation.package_size_amount = package_size_amount
        variation.package_size_unit = normalize_unit(package_size_unit)
        variation.count_per_package = count_per_package
        variation.product_url = str(product_url or "").strip()
        variation.retailer_hint = str(retailer_hint or "").strip()
        variation.notes = str(notes or "").strip()
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
        select(IngredientPreference).where(IngredientPreference.base_ingredient_id == base_ingredient_id)
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
    normalized = _normalized_or_name(cleaned_name, normalized_name)
    cleaned_unit = normalize_unit(unit)
    cleaned_category = _clean_category(category)
    cleaned_notes = str(notes or "").strip()
    cleaned_prep = str(prep or "").strip()

    variation = None
    base = None
    locked = resolution_status == "locked"
    if ingredient_variation_id:
        variation = session.get(IngredientVariation, ingredient_variation_id)
        if variation is not None:
            base = variation.base_ingredient
            locked = locked or True
    if base is None and base_ingredient_id:
        base = session.get(BaseIngredient, base_ingredient_id)

    if variation is None and normalized:
        variation = session.scalar(select(IngredientVariation).where(IngredientVariation.normalized_name == normalized))
        if variation is not None:
            base = variation.base_ingredient
            locked = True

    if base is None and normalized:
        base = session.scalar(select(BaseIngredient).where(BaseIngredient.normalized_name == normalized))

    if base is None and normalized:
        nutrition_item = session.scalar(select(NutritionItem).where(NutritionItem.normalized_name == normalized))
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

    if resolution_status in RESOLUTION_STATUSES:
        final_status = resolution_status
    elif locked and variation is not None:
        final_status = "locked"
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
                ingredient_variation_id=str(ingredient.get("ingredient_variation_id") or "") or None,
                resolution_status=str(ingredient.get("resolution_status") or "") or None,
            ).as_payload(),
        }
        for ingredient in ingredients
        if str(ingredient.get("ingredient_name") or "").strip()
    ]


def choice_for_base_ingredient(
    session: Session,
    *,
    base_ingredient_id: str | None,
    recipe_variation_id: str | None,
    recipe_resolution_status: str,
) -> tuple[BaseIngredient | None, IngredientVariation | None, str]:
    base = session.get(BaseIngredient, base_ingredient_id) if base_ingredient_id else None
    recipe_variation = session.get(IngredientVariation, recipe_variation_id) if recipe_variation_id else None
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
    for row in list(session.scalars(select(RecipeIngredient)).all()) + list(session.scalars(select(WeekMealIngredient)).all()):
        normalized = _normalized_or_name(row.ingredient_name, row.normalized_name)
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
                quantity=getattr(row, "quantity", None) if hasattr(row, "quantity") else getattr(row, "total_quantity", None),
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
