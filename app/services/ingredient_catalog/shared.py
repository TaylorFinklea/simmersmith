from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import BaseIngredient, IngredientVariation

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


def _clean_category(category: str) -> str:
    return str(category or "").strip()


def _normalized_or_name(name: str, normalized_name: str | None = None) -> str:
    return normalize_name(normalized_name or name)


def get_base_ingredient(session: Session, base_ingredient_id: str) -> BaseIngredient | None:
    return session.get(BaseIngredient, base_ingredient_id)


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
