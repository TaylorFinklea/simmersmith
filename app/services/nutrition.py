from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

from sqlalchemy import or_, select
from sqlalchemy.orm import Session, joinedload

from app.models import BaseIngredient, IngredientNutritionMatch, IngredientVariation, NutritionItem
from app.services.grocery import normalize_name


MASS_UNIT_GRAMS = {
    "g": 1.0,
    "gram": 1.0,
    "grams": 1.0,
    "oz": 28.3495,
    "ounce": 28.3495,
    "ounces": 28.3495,
    "lb": 453.592,
    "lbs": 453.592,
    "pound": 453.592,
    "pounds": 453.592,
}

VOLUME_UNIT_ML = {
    "ml": 1.0,
    "milliliter": 1.0,
    "milliliters": 1.0,
    "tsp": 4.92892,
    "teaspoon": 4.92892,
    "teaspoons": 4.92892,
    "tbsp": 14.7868,
    "tablespoon": 14.7868,
    "tablespoons": 14.7868,
    "fl oz": 29.5735,
    "fluid ounce": 29.5735,
    "fluid ounces": 29.5735,
    "cup": 236.588,
    "cups": 236.588,
    "gal": 3785.41,
    "gallon": 3785.41,
    "gallons": 3785.41,
}


@dataclass(frozen=True)
class MacroBreakdown:
    """Per-serving or absolute nutrition totals."""
    calories: float = 0.0
    protein_g: float = 0.0
    carbs_g: float = 0.0
    fat_g: float = 0.0
    fiber_g: float = 0.0

    def as_payload(self) -> dict[str, float]:
        return {
            "calories": round(self.calories, 1),
            "protein_g": round(self.protein_g, 1),
            "carbs_g": round(self.carbs_g, 1),
            "fat_g": round(self.fat_g, 1),
            "fiber_g": round(self.fiber_g, 1),
        }

    def __add__(self, other: "MacroBreakdown") -> "MacroBreakdown":
        return MacroBreakdown(
            calories=self.calories + other.calories,
            protein_g=self.protein_g + other.protein_g,
            carbs_g=self.carbs_g + other.carbs_g,
            fat_g=self.fat_g + other.fat_g,
            fiber_g=self.fiber_g + other.fiber_g,
        )

    def scaled(self, factor: float) -> "MacroBreakdown":
        return MacroBreakdown(
            calories=self.calories * factor,
            protein_g=self.protein_g * factor,
            carbs_g=self.carbs_g * factor,
            fat_g=self.fat_g * factor,
            fiber_g=self.fiber_g * factor,
        )

    @property
    def is_empty(self) -> bool:
        return (
            self.calories == 0.0
            and self.protein_g == 0.0
            and self.carbs_g == 0.0
            and self.fat_g == 0.0
            and self.fiber_g == 0.0
        )


@dataclass(frozen=True)
class NutritionSummary:
    total_calories: float | None
    calories_per_serving: float | None
    coverage_status: str
    matched_ingredient_count: int
    unmatched_ingredient_count: int
    unmatched_ingredients: list[str]
    last_calculated_at: datetime

    def as_payload(self) -> dict[str, object]:
        return {
            "total_calories": self.total_calories,
            "calories_per_serving": self.calories_per_serving,
            "coverage_status": self.coverage_status,
            "matched_ingredient_count": self.matched_ingredient_count,
            "unmatched_ingredient_count": self.unmatched_ingredient_count,
            "unmatched_ingredients": self.unmatched_ingredients,
            "last_calculated_at": self.last_calculated_at,
        }


def nutrition_item_payload(item: NutritionItem) -> dict[str, object]:
    return {
        "item_id": item.id,
        "name": item.name,
        "normalized_name": item.normalized_name,
        "reference_amount": item.reference_amount,
        "reference_unit": item.reference_unit,
        "calories": item.calories,
        "notes": item.notes,
    }


def _calories_for_reference(
    quantity: float | None,
    unit: str,
    *,
    reference_amount: float | None,
    reference_unit: str,
    calories: float | None,
) -> float | None:
    if calories is None:
        return None
    if quantity is None or quantity <= 0:
        return None
    if reference_amount is None or reference_amount <= 0:
        return None
    recipe_unit = normalize_name(unit)
    normalized_reference_unit = normalize_name(reference_unit)
    if recipe_unit == normalized_reference_unit:
        factor = quantity / reference_amount
        return round(calories * factor, 2)

    recipe_group = _unit_group(recipe_unit)
    reference_group = _unit_group(normalized_reference_unit)
    if recipe_group and reference_group and recipe_group[0] == reference_group[0]:
        base_quantity = quantity * recipe_group[1]
        reference_quantity = reference_amount * reference_group[1]
        if reference_quantity <= 0:
            return None
        factor = base_quantity / reference_quantity
        return round(calories * factor, 2)
    return None


@lru_cache(maxsize=1)
def nutrition_seed_items() -> list[dict[str, object]]:
    repo_root = Path(__file__).resolve().parents[2]
    raw = (repo_root / "app" / "data" / "nutrition_items.json").read_text(encoding="utf-8")
    payload = json.loads(raw)
    return payload if isinstance(payload, list) else []


@lru_cache(maxsize=1)
def ingredient_macro_seed() -> list[dict[str, object]]:
    """Load the curated macro seed (per-100g USDA values).

    Entries with `skip: true` (e.g. the metadata header row) are dropped so
    callers can iterate safely.
    """
    repo_root = Path(__file__).resolve().parents[2]
    path = repo_root / "app" / "data" / "ingredient_macros.json"
    if not path.exists():
        return []
    raw = path.read_text(encoding="utf-8")
    payload = json.loads(raw)
    if not isinstance(payload, list):
        return []
    return [entry for entry in payload if isinstance(entry, dict) and not entry.get("skip")]


def ensure_ingredient_macros_seed(session: Session) -> int:
    """Apply the curated macro seed to the base-ingredient catalog.

    - If a `BaseIngredient` with the seed's `normalized_name` already exists,
      only fields that are currently null on the DB row are updated. Existing
      USDA/Open Food Facts values are left alone.
    - If the base ingredient does not exist, a new row is created with the
      seed as its source (`source_name="SimmerSmith Macro Seed"`).

    Returns the number of rows created or updated.
    """
    from app.services.ingredient_catalog import ensure_base_ingredient

    applied = 0
    for entry in ingredient_macro_seed():
        name = str(entry.get("name") or "").strip()
        normalized = str(entry.get("normalized_name") or "").strip()
        if not name or not normalized:
            continue
        ensure_base_ingredient(
            session,
            name=name,
            normalized_name=normalized,
            category=str(entry.get("category") or "").strip(),
            default_unit="g",
            source_name="SimmerSmith Macro Seed",
            source_record_id=normalized,
            source_url="",
            provisional=False,
            active=True,
            nutrition_reference_amount=100.0,
            nutrition_reference_unit="g",
            calories=_seed_float(entry.get("calories")),
            protein_g=_seed_float(entry.get("protein_g")),
            carbs_g=_seed_float(entry.get("carbs_g")),
            fat_g=_seed_float(entry.get("fat_g")),
            fiber_g=_seed_float(entry.get("fiber_g")),
        )
        applied += 1
    session.flush()
    return applied


def _seed_float(value: object) -> float | None:
    if value is None:
        return None
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def ensure_nutrition_defaults(session: Session) -> None:
    existing = {
        item.normalized_name: item
        for item in session.scalars(select(NutritionItem)).all()
    }
    for seed in nutrition_seed_items():
        name = str(seed.get("name") or "").strip()
        if not name:
            continue
        normalized_name = normalize_name(name)
        item = existing.get(normalized_name)
        if item is None:
            item = NutritionItem(
                name=name,
                normalized_name=normalized_name,
                reference_amount=float(seed.get("reference_amount") or 1.0),
                reference_unit=str(seed.get("reference_unit") or "ea").strip() or "ea",
                calories=float(seed.get("calories") or 0.0),
                notes=str(seed.get("notes") or ""),
            )
            session.add(item)
            existing[normalized_name] = item
        else:
            item.name = name
            item.reference_amount = float(seed.get("reference_amount") or 1.0)
            item.reference_unit = str(seed.get("reference_unit") or "ea").strip() or "ea"
            item.calories = float(seed.get("calories") or 0.0)
            item.notes = str(seed.get("notes") or "")
    session.flush()


def search_nutrition_items(session: Session, query: str, limit: int = 20) -> list[NutritionItem]:
    ensure_nutrition_defaults(session)
    statement = select(NutritionItem).order_by(NutritionItem.name).limit(max(1, min(limit, 50)))
    normalized_query = normalize_name(query)
    if normalized_query:
        like_value = f"%{normalized_query}%"
        statement = (
            select(NutritionItem)
            .where(
                or_(
                    NutritionItem.normalized_name.like(like_value),
                    NutritionItem.name.like(f"%{query.strip()}%"),
                )
            )
            .order_by(NutritionItem.name)
            .limit(max(1, min(limit, 50)))
        )
    return list(session.scalars(statement).all())


def save_ingredient_nutrition_match(
    session: Session,
    ingredient_name: str,
    normalized_name: str | None,
    nutrition_item_id: str,
) -> IngredientNutritionMatch:
    ensure_nutrition_defaults(session)
    item = session.get(NutritionItem, nutrition_item_id)
    if item is None:
        raise ValueError("Nutrition item not found")
    normalized_ingredient_name = normalize_name(normalized_name or ingredient_name)
    if not normalized_ingredient_name:
        raise ValueError("Ingredient name is required")
    match = session.scalar(
        select(IngredientNutritionMatch).where(
            IngredientNutritionMatch.normalized_ingredient_name == normalized_ingredient_name
        )
    )
    if match is None:
        match = IngredientNutritionMatch(
            ingredient_name=ingredient_name.strip() or normalized_ingredient_name,
            normalized_ingredient_name=normalized_ingredient_name,
            nutrition_item=item,
        )
        session.add(match)
    else:
        match.ingredient_name = ingredient_name.strip() or match.ingredient_name
        match.nutrition_item = item
    session.flush()
    return match


def ingredient_nutrition_match_payload(match: IngredientNutritionMatch) -> dict[str, object]:
    return {
        "match_id": match.id,
        "ingredient_name": match.ingredient_name,
        "normalized_name": match.normalized_ingredient_name,
        "nutrition_item": nutrition_item_payload(match.nutrition_item),
        "updated_at": match.updated_at,
    }


def _unit_group(unit: str) -> tuple[str, float] | None:
    normalized_unit = normalize_name(unit)
    if normalized_unit in MASS_UNIT_GRAMS:
        return ("mass", MASS_UNIT_GRAMS[normalized_unit])
    if normalized_unit in VOLUME_UNIT_ML:
        return ("volume", VOLUME_UNIT_ML[normalized_unit])
    return None


def _calories_for_item(quantity: float | None, unit: str, item: NutritionItem) -> float | None:
    return _calories_for_reference(
        quantity,
        unit,
        reference_amount=item.reference_amount,
        reference_unit=item.reference_unit,
        calories=item.calories,
    )


def _lookup_catalog_calories(
    session: Session,
    *,
    base_ingredient_id: str | None,
    ingredient_variation_id: str | None,
    quantity: float | None,
    unit: str,
) -> float | None:
    if ingredient_variation_id:
        variation = session.get(IngredientVariation, ingredient_variation_id)
        if variation is not None:
            calories = _calories_for_reference(
                quantity,
                unit,
                reference_amount=variation.nutrition_reference_amount,
                reference_unit=variation.nutrition_reference_unit,
                calories=variation.calories,
            )
            if calories is not None:
                return calories
            base_ingredient_id = variation.base_ingredient_id
    if base_ingredient_id:
        base = session.get(BaseIngredient, base_ingredient_id)
        if base is not None:
            return _calories_for_reference(
                quantity,
                unit,
                reference_amount=base.nutrition_reference_amount,
                reference_unit=base.nutrition_reference_unit,
                calories=base.calories,
            )
    return None


def _macros_for_reference(
    quantity: float | None,
    unit: str,
    *,
    reference_amount: float | None,
    reference_unit: str,
    calories: float | None,
    protein_g: float | None,
    carbs_g: float | None,
    fat_g: float | None,
    fiber_g: float | None,
) -> MacroBreakdown | None:
    """Return a scaled MacroBreakdown for the given `(quantity, unit)` pair.

    Uses the same scaling factor the calories helper uses, but applied to the
    macro tuple. Returns None when we can't compute at least one value (e.g.
    unknown reference unit, or all macro fields are null).
    """
    if reference_amount is None or reference_amount <= 0:
        return None
    if quantity is None or quantity <= 0:
        return None
    if (
        calories is None
        and protein_g is None
        and carbs_g is None
        and fat_g is None
        and fiber_g is None
    ):
        return None

    recipe_unit = normalize_name(unit)
    normalized_reference_unit = normalize_name(reference_unit)
    if recipe_unit == normalized_reference_unit:
        factor = quantity / reference_amount
    else:
        recipe_group = _unit_group(recipe_unit)
        reference_group = _unit_group(normalized_reference_unit)
        if not (
            recipe_group and reference_group and recipe_group[0] == reference_group[0]
        ):
            return None
        base_quantity = quantity * recipe_group[1]
        reference_quantity = reference_amount * reference_group[1]
        if reference_quantity <= 0:
            return None
        factor = base_quantity / reference_quantity

    return MacroBreakdown(
        calories=(calories or 0.0) * factor,
        protein_g=(protein_g or 0.0) * factor,
        carbs_g=(carbs_g or 0.0) * factor,
        fat_g=(fat_g or 0.0) * factor,
        fiber_g=(fiber_g or 0.0) * factor,
    )


def _lookup_catalog_macros(
    session: Session,
    *,
    base_ingredient_id: str | None,
    ingredient_variation_id: str | None,
    quantity: float | None,
    unit: str,
) -> MacroBreakdown | None:
    if ingredient_variation_id:
        variation = session.get(IngredientVariation, ingredient_variation_id)
        if variation is not None:
            macros = _macros_for_reference(
                quantity,
                unit,
                reference_amount=variation.nutrition_reference_amount,
                reference_unit=variation.nutrition_reference_unit,
                calories=variation.calories,
                protein_g=variation.protein_g,
                carbs_g=variation.carbs_g,
                fat_g=variation.fat_g,
                fiber_g=variation.fiber_g,
            )
            if macros is not None and not macros.is_empty:
                return macros
            base_ingredient_id = variation.base_ingredient_id
    if base_ingredient_id:
        base = session.get(BaseIngredient, base_ingredient_id)
        if base is not None:
            return _macros_for_reference(
                quantity,
                unit,
                reference_amount=base.nutrition_reference_amount,
                reference_unit=base.nutrition_reference_unit,
                calories=base.calories,
                protein_g=base.protein_g,
                carbs_g=base.carbs_g,
                fat_g=base.fat_g,
                fiber_g=base.fiber_g,
            )
    return None


def calculate_meal_macros(
    session: Session,
    ingredients: list[dict[str, Any]],
) -> MacroBreakdown:
    """Sum macro contributions across a meal's ingredients.

    Ingredients that can't be resolved contribute zero; we return partial
    coverage rather than refuse. The caller decides whether a meal's macros
    are trustworthy (e.g. by counting how many ingredients resolved).
    """
    total = MacroBreakdown()
    for ingredient in ingredients:
        quantity_raw = ingredient.get("quantity")
        try:
            quantity_value = float(quantity_raw) if quantity_raw is not None else None
        except (TypeError, ValueError):
            quantity_value = None
        unit = str(ingredient.get("unit") or "").strip()
        base_id = str(ingredient.get("base_ingredient_id") or "") or None
        variation_id = str(ingredient.get("ingredient_variation_id") or "") or None
        macros = _lookup_catalog_macros(
            session,
            base_ingredient_id=base_id,
            ingredient_variation_id=variation_id,
            quantity=quantity_value,
            unit=unit,
        )
        if macros is None:
            # Calorie-only fallback via NutritionItem catalog (no macros yet).
            ingredient_name = str(ingredient.get("ingredient_name") or "").strip()
            normalized_name = str(ingredient.get("normalized_name") or "").strip() or None
            item = _lookup_nutrition_item(session, ingredient_name, normalized_name)
            if item is not None:
                calories = _calories_for_item(quantity_value, unit, item)
                if calories is not None:
                    total = total + MacroBreakdown(calories=calories)
            continue
        total = total + macros
    return total


def _lookup_nutrition_item(session: Session, ingredient_name: str, normalized_name: str | None) -> NutritionItem | None:
    ensure_nutrition_defaults(session)
    normalized = normalize_name(normalized_name or ingredient_name)
    if not normalized:
        return None
    match = session.scalar(
        select(IngredientNutritionMatch)
        .options(joinedload(IngredientNutritionMatch.nutrition_item))
        .where(IngredientNutritionMatch.normalized_ingredient_name == normalized)
    )
    if match is not None:
        return match.nutrition_item
    return session.scalar(select(NutritionItem).where(NutritionItem.normalized_name == normalized))


def calculate_recipe_nutrition(
    session: Session,
    ingredients: list[dict[str, Any]],
    servings: float | None,
) -> NutritionSummary:
    ensure_nutrition_defaults(session)
    total_calories = 0.0
    matched = 0
    unmatched_names: list[str] = []
    seen_unmatched: set[str] = set()

    for ingredient in ingredients:
        ingredient_name = str(ingredient.get("ingredient_name") or "").strip()
        normalized_name = str(ingredient.get("normalized_name") or "").strip() or None
        quantity = ingredient.get("quantity")
        try:
            quantity_value = float(quantity) if quantity is not None else None
        except (TypeError, ValueError):
            quantity_value = None
        unit = str(ingredient.get("unit") or "").strip()
        calories = _lookup_catalog_calories(
            session,
            base_ingredient_id=str(ingredient.get("base_ingredient_id") or "") or None,
            ingredient_variation_id=str(ingredient.get("ingredient_variation_id") or "") or None,
            quantity=quantity_value,
            unit=unit,
        )
        if calories is None:
            item = _lookup_nutrition_item(session, ingredient_name, normalized_name)
            calories = _calories_for_item(quantity_value, unit, item) if item is not None else None
        if calories is None:
            key = normalized_name or normalize_name(ingredient_name)
            if ingredient_name and key not in seen_unmatched:
                seen_unmatched.add(key)
                unmatched_names.append(ingredient_name)
            continue
        total_calories += calories
        matched += 1

    unmatched_count = len(unmatched_names)
    if matched == 0:
        coverage_status = "unavailable"
    elif unmatched_count == 0:
        coverage_status = "complete"
    else:
        coverage_status = "partial"

    calories_per_serving = None
    if servings is not None and servings > 0 and matched > 0:
        calories_per_serving = round(total_calories / servings, 1)

    return NutritionSummary(
        total_calories=round(total_calories, 1) if matched > 0 else None,
        calories_per_serving=calories_per_serving,
        coverage_status=coverage_status,
        matched_ingredient_count=matched,
        unmatched_ingredient_count=unmatched_count,
        unmatched_ingredients=unmatched_names,
        last_calculated_at=datetime.now(timezone.utc),
    )
