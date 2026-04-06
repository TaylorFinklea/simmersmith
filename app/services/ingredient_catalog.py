from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.models import (
    BaseIngredient,
    GroceryItem,
    IngredientPreference,
    IngredientVariation,
    NutritionItem,
    Recipe,
    RecipeIngredient,
    WeekMealIngredient,
    utcnow,
)

MAX_LINKED_ITEMS = 20


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

LEADING_QUANTITY_PATTERN = re.compile(
    r"^\s*\d+(?:\s+\d+/\d+|\.\d+|/\d+)?\s*(?:%|count|counts|ct|each|ea|lb|lbs|pound|pounds|oz|ounce|ounces|"
    r"fl oz|fluid ounce|fluid ounces|gal|gallon|gallons|cup|cups|tbsp|tablespoon|tablespoons|tsp|teaspoon|"
    r"teaspoons|pkg|package|packages|can|cans|bag|bags|bunch|bunches|clove|cloves|slice|slices)?\s+",
    re.IGNORECASE,
)
PACKAGE_SIZE_PATTERN = re.compile(
    r"\b\d+(?:\.\d+)?\s?(?:g|kg|oz|lb|lbs|ml|l|ct|count|pack|pk)\b",
    re.IGNORECASE,
)
MARKETING_PREFIXES = {
    "classic",
    "natural",
    "organic",
    "original",
    "prepared",
    "traditional",
}
PACKAGING_TOKENS = {
    "bag",
    "bags",
    "bottle",
    "bottles",
    "box",
    "boxes",
    "can",
    "cans",
    "carton",
    "cartons",
    "jar",
    "jars",
    "pack",
    "packs",
    "package",
    "packages",
    "pouch",
    "pouches",
    "tin",
    "tins",
    "tube",
    "tubes",
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


@dataclass(frozen=True)
class IngredientUsageSummary:
    linked_recipe_ids: list[str]
    linked_recipe_names: list[str]
    linked_grocery_item_ids: list[str]
    linked_grocery_names: list[str]

    def as_payload(self) -> dict[str, object]:
        return {
            "linked_recipe_ids": self.linked_recipe_ids,
            "linked_recipe_names": self.linked_recipe_names,
            "linked_grocery_item_ids": self.linked_grocery_item_ids,
            "linked_grocery_names": self.linked_grocery_names,
        }


@dataclass(frozen=True)
class VariationCandidate:
    name: str
    normalized_name: str
    brand: str
    upc: str
    package_size_amount: float | None
    package_size_unit: str
    count_per_package: float | None
    product_url: str
    retailer_hint: str
    notes: str
    source_name: str
    source_record_id: str
    source_url: str
    source_payload: dict[str, Any]
    nutrition_reference_amount: float | None
    nutrition_reference_unit: str
    calories: float | None


@dataclass(frozen=True)
class ProductLikeRewritePlan:
    source_base_id: str
    source_base_name: str
    source_normalized_name: str
    target_base_id: str | None
    target_base_name: str
    target_normalized_name: str
    target_action: str
    variation_action: str
    variation_name: str | None
    variation_brand: str
    apply_variation_to_rows: bool
    merge_base: bool
    skip_reason: str | None = None

    def as_payload(self) -> dict[str, object]:
        return {
            "source_base_id": self.source_base_id,
            "source_base_name": self.source_base_name,
            "source_normalized_name": self.source_normalized_name,
            "target_base_id": self.target_base_id,
            "target_base_name": self.target_base_name,
            "target_normalized_name": self.target_normalized_name,
            "target_action": self.target_action,
            "variation_action": self.variation_action,
            "variation_name": self.variation_name,
            "variation_brand": self.variation_brand,
            "apply_variation_to_rows": self.apply_variation_to_rows,
            "merge_base": self.merge_base,
            "skip_reason": self.skip_reason,
        }


@dataclass(frozen=True)
class ProductLikeRewriteResult:
    total_candidates: int
    actionable_count: int
    skipped_count: int
    merged_count: int
    variation_created_count: int
    variation_reused_count: int

    def as_payload(self) -> dict[str, object]:
        return {
            "total_candidates": self.total_candidates,
            "actionable_count": self.actionable_count,
            "skipped_count": self.skipped_count,
            "merged_count": self.merged_count,
            "variation_created_count": self.variation_created_count,
            "variation_reused_count": self.variation_reused_count,
        }


def _source_payload(item: BaseIngredient) -> dict[str, Any]:
    try:
        return json.loads(item.source_payload_json or "{}")
    except json.JSONDecodeError:
        return {}


def cleaned_base_ingredient_name(
    name: str, *, source_name: str = "", source_payload: dict[str, Any] | None = None
) -> str:
    text = str(name or "").strip()
    if not text:
        return ""

    text = re.sub(r"\([^)]*\)", " ", text)
    text = LEADING_QUANTITY_PATTERN.sub("", text)
    text = PACKAGE_SIZE_PATTERN.sub(" ", text)
    text = re.sub(r"\b\d+%\b", " ", text)

    if source_name == "Open Food Facts" and source_payload:
        brand_text = str(source_payload.get("brands") or "").split(",")[0].strip()
        if brand_text:
            brand_pattern = re.compile(rf"\b{re.escape(brand_text)}\b", re.IGNORECASE)
            text = brand_pattern.sub(" ", text)

    text = re.sub(r"[,;/]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" -")
    tokens = text.split()
    while tokens and normalize_name(tokens[0]) in MARKETING_PREFIXES:
        tokens = tokens[1:]
    text = " ".join(tokens)
    text = re.sub(r"\bprepared mustard\b", "mustard", text, flags=re.IGNORECASE)
    text = re.sub(r"\s+", " ", text).strip(" -")
    if not text:
        return ""
    return text[:1].upper() + text[1:]


def is_product_like_base_ingredient(item: BaseIngredient) -> bool:
    payload = _source_payload(item)
    cleaned = cleaned_base_ingredient_name(
        item.name, source_name=item.source_name, source_payload=payload
    )
    normalized_cleaned = normalize_name(cleaned)
    tokens = item.normalized_name.split()
    if item.source_name == "Open Food Facts":
        if payload.get("brands"):
            return True
        if normalized_cleaned and normalized_cleaned != item.normalized_name:
            return True
    leading_token = item.normalized_name.split(" ", 1)[0] if item.normalized_name else ""
    if leading_token.isdigit():
        return True
    if tokens and tokens[-1] in PACKAGING_TOKENS:
        return True
    if PACKAGE_SIZE_PATTERN.search(item.name):
        return True
    if (
        normalized_cleaned
        and normalized_cleaned != item.normalized_name
        and bool(LEADING_QUANTITY_PATTERN.match(item.name))
    ):
        return True
    return False


def _clean_category(category: str) -> str:
    return str(category or "").strip()


def _strong_product_evidence(item: BaseIngredient) -> bool:
    payload = _source_payload(item)
    brand_text = str(payload.get("brands") or payload.get("brand") or "").strip()
    if item.source_name == "Open Food Facts":
        return bool(brand_text or item.source_record_id or item.source_url)
    return False


def _variation_candidate_from_base(item: BaseIngredient) -> VariationCandidate | None:
    if not _strong_product_evidence(item):
        return None
    payload = _source_payload(item)
    brand = str(payload.get("brands") or payload.get("brand") or "").split(",")[0].strip()
    name = str(payload.get("product_name") or item.name or "").strip()
    if not name:
        return None
    upc = str(payload.get("code") or item.source_record_id or "").strip()
    return VariationCandidate(
        name=name,
        normalized_name=item.normalized_name,
        brand=brand,
        upc=upc,
        package_size_amount=None,
        package_size_unit="",
        count_per_package=None,
        product_url=str(item.source_url or "").strip(),
        retailer_hint=str(item.source_name or "").strip(),
        notes=str(item.notes or "").strip(),
        source_name=str(item.source_name or "").strip(),
        source_record_id=str(item.source_record_id or "").strip(),
        source_url=str(item.source_url or "").strip(),
        source_payload=payload,
        nutrition_reference_amount=item.nutrition_reference_amount,
        nutrition_reference_unit=item.nutrition_reference_unit,
        calories=item.calories,
    )


def _active_base_by_normalized_name(
    session: Session, normalized_name: str
) -> BaseIngredient | None:
    base = session.scalar(
        select(BaseIngredient).where(BaseIngredient.normalized_name == normalized_name)
    )
    if base is not None and (base.archived_at is not None or not base.active):
        return None
    return base


def _active_variation_by_normalized_name(
    session: Session,
    *,
    base_ingredient_id: str,
    normalized_name: str,
) -> IngredientVariation | None:
    variation = session.scalar(
        select(IngredientVariation).where(
            IngredientVariation.base_ingredient_id == base_ingredient_id,
            IngredientVariation.normalized_name == normalized_name,
        )
    )
    if variation is not None and (variation.archived_at is not None or not variation.active):
        return None
    return variation


def _normalized_or_name(name: str, normalized_name: str | None = None) -> str:
    return normalize_name(normalized_name or name)


def _ingredient_search_score(
    item: BaseIngredient, normalized_query: str
) -> tuple[int, int, int, int, int, str]:
    normalized_name = item.normalized_name
    is_exact = int(normalized_name == normalized_query)
    starts_with = int(normalized_name.startswith(normalized_query))
    contains = int(normalized_query in normalized_name)
    leading_token = normalized_name.split(" ", 1)[0] if normalized_name else ""
    literal_penalty = int(
        leading_token.isdigit() or leading_token in {"can", "cans", "pkg", "package", "packages"}
    )
    product_like_penalty = int(is_product_like_base_ingredient(item))
    source_penalty = int(bool(item.source_name and item.source_name != "USDA FoodData Central"))
    return (
        -is_exact,
        -starts_with,
        -contains,
        literal_penalty,
        product_like_penalty,
        source_penalty,
        len(normalized_name),
        normalized_name,
    )


def _normalized_phrase_match(column, normalized_query: str):
    variants = {normalized_query}
    parts = normalized_query.split()
    if parts:
        last = parts[-1]
        if last.endswith("s") and len(last) > 3:
            variants.add(" ".join([*parts[:-1], last[:-1]]))
        elif len(last) > 2:
            variants.add(" ".join([*parts[:-1], f"{last}s"]))
    clauses = []
    for variant in variants:
        clauses.extend(
            [
                column == variant,
                column.like(f"{variant} %"),
                column.like(f"% {variant} %"),
                column.like(f"% {variant}"),
            ]
        )
    return or_(*clauses)


def search_base_ingredients(
    session: Session,
    query: str = "",
    *,
    limit: int = 20,
    include_archived: bool = False,
    provisional_only: bool = False,
    with_preferences: bool = False,
    with_variations: bool = False,
    include_product_like: bool = False,
) -> list[BaseIngredient]:
    statement = select(BaseIngredient)
    if not include_archived:
        statement = statement.where(
            BaseIngredient.archived_at.is_(None), BaseIngredient.active.is_(True)
        )
    if provisional_only:
        statement = statement.where(BaseIngredient.provisional.is_(True))
    if with_preferences:
        statement = statement.where(
            BaseIngredient.id.in_(
                select(IngredientPreference.base_ingredient_id).where(
                    IngredientPreference.active.is_(True)
                )
            )
        )
    if with_variations:
        statement = statement.where(
            BaseIngredient.id.in_(
                select(IngredientVariation.base_ingredient_id).where(
                    IngredientVariation.archived_at.is_(None),
                    IngredientVariation.active.is_(True),
                )
            )
        )
    normalized_query = normalize_name(query)
    if normalized_query:
        statement = statement.where(
            or_(
                _normalized_phrase_match(BaseIngredient.normalized_name, normalized_query),
                BaseIngredient.id.in_(
                    select(IngredientVariation.base_ingredient_id).where(
                        or_(
                            _normalized_phrase_match(
                                IngredientVariation.normalized_name, normalized_query
                            ),
                            IngredientVariation.brand.ilike(f"%{query.strip()}%"),
                            IngredientVariation.upc.ilike(f"%{query.strip()}%"),
                        ),
                        IngredientVariation.archived_at.is_(None),
                        IngredientVariation.active.is_(True),
                    )
                ),
            )
        )
    safe_limit = max(1, min(limit, 200))
    if normalized_query:
        items = list(session.scalars(statement.limit(200)).all())
        if not include_product_like:
            items = [item for item in items if not is_product_like_base_ingredient(item)]
        items.sort(key=lambda item: _ingredient_search_score(item, normalized_query))
        return items[:safe_limit]
    if not include_product_like:
        statement = statement.where(BaseIngredient.source_name != "Open Food Facts")
    statement = statement.order_by(
        BaseIngredient.provisional.asc(),
        func.length(BaseIngredient.name),
        BaseIngredient.name,
    ).limit(safe_limit)
    items = list(session.scalars(statement).all())
    if not include_product_like:
        items = [item for item in items if not is_product_like_base_ingredient(item)]
    return items[:safe_limit]


def get_base_ingredient(session: Session, base_ingredient_id: str) -> BaseIngredient | None:
    return session.get(BaseIngredient, base_ingredient_id)


def ingredient_usage_summary(session: Session, base_ingredient_id: str) -> IngredientUsageSummary:
    recipe_rows = list(
        session.execute(
            select(Recipe.id, Recipe.name)
            .join(RecipeIngredient, RecipeIngredient.recipe_id == Recipe.id)
            .where(RecipeIngredient.base_ingredient_id == base_ingredient_id)
            .order_by(Recipe.name)
        )
    )
    grocery_rows = list(
        session.execute(
            select(GroceryItem.id, GroceryItem.ingredient_name)
            .where(GroceryItem.base_ingredient_id == base_ingredient_id)
            .order_by(GroceryItem.ingredient_name)
        )
    )
    seen_recipe_ids: set[str] = set()
    linked_recipe_ids: list[str] = []
    linked_recipe_names: list[str] = []
    for recipe_id, ingredient_name in recipe_rows:
        if recipe_id in seen_recipe_ids:
            continue
        seen_recipe_ids.add(recipe_id)
        linked_recipe_ids.append(recipe_id)
        linked_recipe_names.append(ingredient_name)

    return IngredientUsageSummary(
        linked_recipe_ids=linked_recipe_ids[:MAX_LINKED_ITEMS],
        linked_recipe_names=linked_recipe_names[:MAX_LINKED_ITEMS],
        linked_grocery_item_ids=[row[0] for row in grocery_rows[:MAX_LINKED_ITEMS]],
        linked_grocery_names=[row[1] for row in grocery_rows[:MAX_LINKED_ITEMS]],
    )


def ingredient_counts(session: Session, base_ingredient_id: str) -> dict[str, int]:
    return {
        "variation_count": session.scalar(
            select(func.count(IngredientVariation.id)).where(
                IngredientVariation.base_ingredient_id == base_ingredient_id,
                IngredientVariation.archived_at.is_(None),
                IngredientVariation.active.is_(True),
            )
        )
        or 0,
        "preference_count": session.scalar(
            select(func.count(IngredientPreference.id)).where(
                IngredientPreference.base_ingredient_id == base_ingredient_id
            )
        )
        or 0,
        "recipe_usage_count": session.scalar(
            select(func.count(RecipeIngredient.id)).where(
                RecipeIngredient.base_ingredient_id == base_ingredient_id
            )
        )
        or 0,
        "grocery_usage_count": session.scalar(
            select(func.count(GroceryItem.id)).where(
                GroceryItem.base_ingredient_id == base_ingredient_id
            )
        )
        or 0,
    }


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


def _repoint_base_usage_to_variation(
    session: Session,
    *,
    source_base_id: str,
    target_variation: IngredientVariation,
) -> None:
    for model in (RecipeIngredient, WeekMealIngredient, GroceryItem):
        rows = session.scalars(
            select(model).where(
                model.base_ingredient_id == source_base_id,
                model.ingredient_variation_id.is_(None),
            )
        ).all()
        for row in rows:
            row.base_ingredient_id = target_variation.base_ingredient_id
            row.ingredient_variation_id = target_variation.id
            if row.resolution_status != "locked":
                row.resolution_status = "suggested"

    preference = ingredient_preference_for_base(session, source_base_id)
    if preference is not None and preference.preferred_variation_id is None:
        preference.preferred_variation_id = target_variation.id


def plan_product_like_base_rewrites(
    session: Session,
    *,
    limit: int | None = None,
) -> list[ProductLikeRewritePlan]:
    rows = list(
        session.scalars(
            select(BaseIngredient)
            .where(
                BaseIngredient.archived_at.is_(None),
                BaseIngredient.active.is_(True),
            )
            .order_by(BaseIngredient.name)
        ).all()
    )
    plans: list[ProductLikeRewritePlan] = []
    for row in rows:
        if limit is not None and len(plans) >= limit:
            break
        if row.archived_at is not None or not row.active:
            continue
        if not is_product_like_base_ingredient(row):
            continue
        cleaned_name = cleaned_base_ingredient_name(
            row.name,
            source_name=row.source_name,
            source_payload=_source_payload(row),
        )
        if not cleaned_name:
            plans.append(
                ProductLikeRewritePlan(
                    source_base_id=row.id,
                    source_base_name=row.name,
                    source_normalized_name=row.normalized_name,
                    target_base_id=None,
                    target_base_name="",
                    target_normalized_name="",
                    target_action="skip",
                    variation_action="skip",
                    variation_name=None,
                    variation_brand="",
                    apply_variation_to_rows=False,
                    merge_base=False,
                    skip_reason="empty_clean_generic_name",
                )
            )
            continue
        normalized_cleaned = normalize_name(cleaned_name)
        if not normalized_cleaned:
            plans.append(
                ProductLikeRewritePlan(
                    source_base_id=row.id,
                    source_base_name=row.name,
                    source_normalized_name=row.normalized_name,
                    target_base_id=None,
                    target_base_name=cleaned_name,
                    target_normalized_name="",
                    target_action="skip",
                    variation_action="skip",
                    variation_name=None,
                    variation_brand="",
                    apply_variation_to_rows=False,
                    merge_base=False,
                    skip_reason="empty_clean_generic_normalized_name",
                )
            )
            continue
        if normalized_cleaned == row.normalized_name:
            plans.append(
                ProductLikeRewritePlan(
                    source_base_id=row.id,
                    source_base_name=row.name,
                    source_normalized_name=row.normalized_name,
                    target_base_id=row.id,
                    target_base_name=cleaned_name,
                    target_normalized_name=normalized_cleaned,
                    target_action="skip",
                    variation_action="skip",
                    variation_name=None,
                    variation_brand="",
                    apply_variation_to_rows=False,
                    merge_base=False,
                    skip_reason="generic_name_unchanged",
                )
            )
            continue

        target = _active_base_by_normalized_name(session, normalized_cleaned)
        variation_candidate = _variation_candidate_from_base(row)
        variation_action = "skip"
        variation_name: str | None = None
        variation_brand = ""
        apply_variation_to_rows = False
        if variation_candidate is not None:
            variation_name = variation_candidate.name
            variation_brand = variation_candidate.brand
            if target is not None and _active_variation_by_normalized_name(
                session,
                base_ingredient_id=target.id,
                normalized_name=variation_candidate.normalized_name,
            ):
                variation_action = "reuse"
            else:
                variation_action = "create"
            apply_variation_to_rows = True

        plans.append(
            ProductLikeRewritePlan(
                source_base_id=row.id,
                source_base_name=row.name,
                source_normalized_name=row.normalized_name,
                target_base_id=target.id if target is not None else None,
                target_base_name=cleaned_name,
                target_normalized_name=normalized_cleaned,
                target_action="reuse" if target is not None else "create",
                variation_action=variation_action,
                variation_name=variation_name,
                variation_brand=variation_brand,
                apply_variation_to_rows=apply_variation_to_rows,
                merge_base=True,
                skip_reason=None,
            )
        )
    return plans


def apply_product_like_base_rewrites(
    session: Session,
    *,
    plans: list[ProductLikeRewritePlan] | None = None,
) -> ProductLikeRewriteResult:
    plans = plans if plans is not None else plan_product_like_base_rewrites(session)
    merged_count = 0
    variation_created_count = 0
    variation_reused_count = 0

    for plan in plans:
        if plan.skip_reason is not None or not plan.merge_base:
            continue
        source = get_base_ingredient(session, plan.source_base_id)
        if source is None or source.archived_at is not None or not source.active:
            continue
        target = _active_base_by_normalized_name(session, plan.target_normalized_name)
        if target is None:
            target = ensure_base_ingredient(
                session,
                name=plan.target_base_name,
                normalized_name=plan.target_normalized_name,
                category=source.category,
                default_unit=source.default_unit,
                notes=source.notes,
                provisional=source.provisional,
                active=True,
                nutrition_reference_amount=source.nutrition_reference_amount,
                nutrition_reference_unit=source.nutrition_reference_unit,
                calories=source.calories,
            )
        variation = None
        candidate = _variation_candidate_from_base(source)
        if candidate is not None:
            existing = _active_variation_by_normalized_name(
                session,
                base_ingredient_id=target.id,
                normalized_name=candidate.normalized_name,
            )
            variation = create_or_update_variation(
                session,
                base_ingredient_id=target.id,
                variation_id=existing.id if existing is not None else None,
                name=candidate.name,
                normalized_name=candidate.normalized_name,
                brand=candidate.brand,
                upc=candidate.upc,
                package_size_amount=candidate.package_size_amount,
                package_size_unit=candidate.package_size_unit,
                count_per_package=candidate.count_per_package,
                product_url=candidate.product_url,
                retailer_hint=candidate.retailer_hint,
                notes=candidate.notes,
                source_name=candidate.source_name,
                source_record_id=candidate.source_record_id,
                source_url=candidate.source_url,
                source_payload=candidate.source_payload,
                active=True,
                nutrition_reference_amount=candidate.nutrition_reference_amount,
                nutrition_reference_unit=candidate.nutrition_reference_unit,
                calories=candidate.calories,
            )
            if existing is None:
                variation_created_count += 1
            else:
                variation_reused_count += 1
            _repoint_base_usage_to_variation(
                session, source_base_id=source.id, target_variation=variation
            )
        merge_base_ingredients(session, source_id=source.id, target_id=target.id)
        merged_count += 1

    session.flush()
    total_candidates = len(plans)
    actionable_count = sum(1 for plan in plans if plan.skip_reason is None and plan.merge_base)
    skipped_count = total_candidates - actionable_count
    return ProductLikeRewriteResult(
        total_candidates=total_candidates,
        actionable_count=actionable_count,
        skipped_count=skipped_count,
        merged_count=merged_count,
        variation_created_count=variation_created_count,
        variation_reused_count=variation_reused_count,
    )


def normalize_product_like_base_ingredients(session: Session) -> int:
    result = apply_product_like_base_rewrites(session)
    return result.merged_count


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
    generic_name = cleaned_base_ingredient_name(cleaned_name) or cleaned_name
    generic_normalized = normalize_name(generic_name)
    cleaned_unit = normalize_unit(unit)
    cleaned_category = _clean_category(category)
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
