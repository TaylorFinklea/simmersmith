from __future__ import annotations

from typing import Any

from . import mcp
from ._helpers import _call_route

from app.api.ingredients import (
    create_ingredient_route,
    create_variation_route,
    ingredient_detail_route,
    list_ingredient_preferences_route,
    list_ingredients_route,
    list_variations_route,
    resolve_ingredient_route,
    upsert_ingredient_preference_route,
)
from app.auth import CurrentUser
from app.config import get_settings
from app.db import session_scope
from app.schemas import (
    BaseIngredientPayload,
    IngredientPreferencePayload,
    IngredientResolveRequest,
    IngredientVariationPayload,
)


def _mcp_user() -> CurrentUser:
    return CurrentUser(id=get_settings().local_user_id)


@mcp.tool(description="Search or list canonical base ingredients.")
def ingredients_list(query: str = "", limit: int = 20) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: list_ingredients_route(q=query, limit=limit, session=session))


@mcp.tool(description="Get one canonical base ingredient by ID.")
def ingredients_get(base_ingredient_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: ingredient_detail_route(base_ingredient_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Create or update a canonical base ingredient.")
def ingredients_create(
    name: str,
    normalized_name: str | None = None,
    category: str = "",
    default_unit: str = "",
    notes: str = "",
    nutrition_reference_amount: float | None = None,
    nutrition_reference_unit: str = "",
    calories: float | None = None,
) -> dict[str, Any]:
    with session_scope() as session:
        payload = BaseIngredientPayload(
            name=name,
            normalized_name=normalized_name,
            category=category,
            default_unit=default_unit,
            notes=notes,
            nutrition_reference_amount=nutrition_reference_amount,
            nutrition_reference_unit=nutrition_reference_unit,
            calories=calories,
        )
        return _call_route(lambda: create_ingredient_route(payload, session=session))


@mcp.tool(
    description="Resolve a recipe or grocery ingredient line against the canonical ingredient catalog."
)
def ingredients_resolve(
    ingredient_name: str,
    normalized_name: str | None = None,
    quantity: float | None = None,
    unit: str = "",
    prep: str = "",
    category: str = "",
    notes: str = "",
) -> dict[str, Any]:
    with session_scope() as session:
        payload = IngredientResolveRequest(
            ingredient_name=ingredient_name,
            normalized_name=normalized_name,
            quantity=quantity,
            unit=unit,
            prep=prep,
            category=category,
            notes=notes,
        )
        return _call_route(lambda: resolve_ingredient_route(payload, session=session))


@mcp.tool(description="List ingredient variations for a base ingredient.")
def ingredients_list_variations(base_ingredient_id: str) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: list_variations_route(base_ingredient_id, session=session))


@mcp.tool(description="Create or update a specific ingredient variation under a base ingredient.")
def ingredients_create_variation(
    base_ingredient_id: str,
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
) -> dict[str, Any]:
    with session_scope() as session:
        payload = IngredientVariationPayload(
            name=name,
            normalized_name=normalized_name,
            brand=brand,
            package_size_amount=package_size_amount,
            package_size_unit=package_size_unit,
            count_per_package=count_per_package,
            product_url=product_url,
            retailer_hint=retailer_hint,
            notes=notes,
            nutrition_reference_amount=nutrition_reference_amount,
            nutrition_reference_unit=nutrition_reference_unit,
            calories=calories,
        )
        return _call_route(
            lambda: create_variation_route(base_ingredient_id, payload, session=session)
        )


@mcp.tool(description="List structured ingredient shopping preferences.")
def ingredient_preferences_list() -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: list_ingredient_preferences_route(session=session, current_user=_mcp_user()))


@mcp.tool(description="Create or update a structured ingredient shopping preference.")
def ingredient_preferences_upsert(
    base_ingredient_id: str,
    preferred_variation_id: str | None = None,
    preferred_brand: str = "",
    choice_mode: str = "preferred",
    active: bool = True,
    notes: str = "",
) -> dict[str, Any]:
    with session_scope() as session:
        payload = IngredientPreferencePayload(
            base_ingredient_id=base_ingredient_id,
            preferred_variation_id=preferred_variation_id,
            preferred_brand=preferred_brand,
            choice_mode=choice_mode,
            active=active,
            notes=notes,
        )
        return _call_route(lambda: upsert_ingredient_preference_route(payload, session=session, current_user=_mcp_user()))
