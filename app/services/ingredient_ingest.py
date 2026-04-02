from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib import parse as urllib_parse
from urllib import request as urllib_request

from sqlalchemy.orm import Session

from app.services.ingredient_catalog import create_or_update_variation, ensure_base_ingredient, normalize_name


USDA_API_BASE = "https://api.nal.usda.gov/fdc/v1/foods/search"
OPEN_FOOD_FACTS_API_BASE = "https://world.openfoodfacts.org/cgi/search.pl"

USDA_DEFAULT_SEED_TERMS = [
    "whole milk",
    "butter",
    "heavy cream",
    "eggs",
    "cheddar cheese",
    "mozzarella cheese",
    "yogurt",
    "sour cream",
    "chicken breast",
    "ground beef",
    "beef chuck roast",
    "pork sausage",
    "bacon",
    "salmon",
    "shrimp",
    "white rice",
    "brown rice",
    "spaghetti",
    "penne pasta",
    "flour tortilla",
    "whole wheat bread",
    "all purpose flour",
    "whole wheat flour",
    "cornmeal",
    "rolled oats",
    "granulated sugar",
    "brown sugar",
    "honey",
    "olive oil",
    "vegetable oil",
    "yellow mustard",
    "mayonnaise",
    "barbecue sauce",
    "soy sauce",
    "chicken broth",
    "beef broth",
    "black beans",
    "kidney beans",
    "diced tomatoes",
    "tomato sauce",
    "tomato paste",
    "russet potatoes",
    "sweet potatoes",
    "yellow onion",
    "garlic",
    "broccoli",
    "cauliflower",
    "carrots",
    "celery",
    "bell pepper",
    "spinach",
    "romaine lettuce",
    "green beans",
    "corn kernels",
    "mushrooms",
    "lemons",
    "limes",
    "bananas",
    "strawberries",
    "blueberries",
    "apples",
    "avocado",
    "cilantro",
    "parsley",
    "black pepper",
    "kosher salt",
    "paprika",
    "cumin",
    "chili powder",
    "garlic powder",
    "onion powder",
    "cinnamon",
    "baking powder",
    "baking soda",
    "vanilla extract",
    "maple syrup",
    "peanut butter",
    "jam",
]

OPEN_FOOD_FACTS_DEFAULT_TERMS = [
    "pillsbury biscuits",
    "great value biscuits",
    "annie's mac and cheese",
    "barilla pasta",
    "kraft shredded cheddar",
    "hidden valley ranch",
    "heinz ketchup",
    "french's mustard",
]


@dataclass(frozen=True)
class IngestResult:
    bases_created_or_updated: int
    variations_created_or_updated: int
    source_label: str
    skipped_terms: int = 0


def seed_terms_from_file(path: Path) -> list[str]:
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


def _fetch_json(url: str, *, payload: dict[str, Any] | None = None, headers: dict[str, str] | None = None) -> dict[str, Any]:
    request_headers = {"User-Agent": "SimmerSmith/1.0"} | (headers or {})
    body = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    request = urllib_request.Request(url, data=body, headers=request_headers)
    with urllib_request.urlopen(request, timeout=30.0) as response:
        return json.loads(response.read().decode("utf-8"))


def _usda_calories(food: dict[str, Any]) -> float | None:
    nutrients = food.get("foodNutrients") or []
    for nutrient in nutrients:
        number = str(nutrient.get("nutrientNumber") or "").strip()
        if number == "208":
            value = nutrient.get("value")
            return float(value) if value is not None else None
    return None


def _off_calories(product: dict[str, Any]) -> float | None:
    nutriments = product.get("nutriments") or {}
    for key in ("energy-kcal_100g", "energy-kcal_serving", "energy-kcal"):
        value = nutriments.get(key)
        if value not in {None, ""}:
            try:
                return float(value)
            except (TypeError, ValueError):
                continue
    return None


def _title_case_name(value: str) -> str:
    text = re.sub(r"\s+", " ", value).strip()
    if not text:
        return text
    return text[:1].upper() + text[1:]


def _generic_name_from_product(product_name: str, brand: str) -> str:
    cleaned = product_name.strip()
    brand_text = brand.strip()
    if brand_text:
        pattern = re.compile(rf"^{re.escape(brand_text)}\s+", re.IGNORECASE)
        cleaned = pattern.sub("", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -")
    return cleaned or product_name.strip()


def ingest_usda_terms(
    session: Session,
    *,
    api_key: str,
    terms: Iterable[str],
    page_size: int = 25,
    max_pages: int = 1,
) -> IngestResult:
    base_count = 0
    skipped_terms = 0
    for raw_term in terms:
        term = raw_term.strip()
        if not term:
            continue
        for page_number in range(1, max_pages + 1):
            payload = {
                "query": term,
                "pageSize": page_size,
                "pageNumber": page_number,
                "dataType": ["Foundation", "SR Legacy", "Survey (FNDDS)"],
            }
            url = f"{USDA_API_BASE}?api_key={urllib_parse.quote(api_key)}"
            try:
                data = _fetch_json(url, payload=payload)
            except (HTTPError, URLError) as exc:
                skipped_terms += 1
                print(f"[ingredient-seed] skipped USDA term '{term}' page {page_number}: {exc}")
                break
            foods = data.get("foods") or []
            if not foods:
                break
            for food in foods:
                description = str(food.get("description") or "").strip()
                normalized = normalize_name(description)
                if not normalized:
                    continue
                category = str(food.get("foodCategory") or food.get("foodCategoryDescription") or "").strip()
                ensure_base_ingredient(
                    session,
                    name=_title_case_name(description),
                    normalized_name=normalized,
                    category=category,
                    default_unit="g",
                    notes=str(food.get("additionalDescriptions") or "").strip(),
                    source_name="USDA FoodData Central",
                    source_record_id=str(food.get("fdcId") or ""),
                    source_url=f"https://fdc.nal.usda.gov/fdc-app.html#/food-details/{food.get('fdcId')}/nutrients",
                    source_payload=food,
                    provisional=False,
                    active=True,
                    nutrition_reference_amount=100.0,
                    nutrition_reference_unit="g",
                    calories=_usda_calories(food),
                )
                base_count += 1
    session.flush()
    return IngestResult(
        bases_created_or_updated=base_count,
        variations_created_or_updated=0,
        source_label="USDA FoodData Central",
        skipped_terms=skipped_terms,
    )


def ingest_open_food_facts_terms(
    session: Session,
    *,
    terms: Iterable[str],
    page_size: int = 25,
) -> IngestResult:
    base_count = 0
    variation_count = 0
    skipped_terms = 0
    for raw_term in terms:
        term = raw_term.strip()
        if not term:
            continue
        query = urllib_parse.urlencode(
            {
                "action": "process",
                "json": 1,
                "search_terms": term,
                "page_size": page_size,
            }
        )
        try:
            data = _fetch_json(f"{OPEN_FOOD_FACTS_API_BASE}?{query}")
        except (HTTPError, URLError) as exc:
            skipped_terms += 1
            print(f"[ingredient-seed] skipped Open Food Facts term '{term}': {exc}")
            continue
        products = data.get("products") or []
        for product in products:
            product_name = str(product.get("product_name") or product.get("generic_name") or "").strip()
            if not product_name:
                continue
            brand = str(product.get("brands") or "").split(",")[0].strip()
            base_name = _generic_name_from_product(product_name, brand)
            base = ensure_base_ingredient(
                session,
                name=_title_case_name(base_name),
                normalized_name=normalize_name(base_name),
                category=str(product.get("categories_tags", [""])[0]).replace("en:", "").replace("-", " ").title()
                if product.get("categories_tags")
                else "",
                default_unit="g",
                source_name="Open Food Facts",
                source_record_id=str(product.get("code") or ""),
                source_url=str(product.get("url") or ""),
                source_payload=product,
                provisional=False,
                active=True,
                nutrition_reference_amount=100.0,
                nutrition_reference_unit="g",
                calories=_off_calories(product),
            )
            base_count += 1
            create_or_update_variation(
                session,
                base_ingredient_id=base.id,
                name=_title_case_name(product_name),
                normalized_name=normalize_name(product_name),
                brand=brand,
                upc=str(product.get("code") or ""),
                package_size_amount=None,
                package_size_unit="",
                count_per_package=None,
                product_url=str(product.get("url") or ""),
                retailer_hint="",
                notes=str(product.get("quantity") or "").strip(),
                source_name="Open Food Facts",
                source_record_id=str(product.get("code") or ""),
                source_url=str(product.get("url") or ""),
                source_payload=product,
                active=True,
                nutrition_reference_amount=100.0,
                nutrition_reference_unit="g",
                calories=_off_calories(product),
            )
            variation_count += 1
    session.flush()
    return IngestResult(
        bases_created_or_updated=base_count,
        variations_created_or_updated=variation_count,
        source_label="Open Food Facts",
        skipped_terms=skipped_terms,
    )
