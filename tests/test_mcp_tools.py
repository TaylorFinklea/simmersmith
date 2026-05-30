"""Regression: MCP tools that re-use household-scoped REST handlers must
pass current_user / household_id. Several called the handlers without it
(or passed user_id where household_id was expected), so they raised
AttributeError / TypeError on every invocation. These call the tools in
open mode (conftest: no auth configured -> local dev user + solo
household) and assert they return without error.
"""
from __future__ import annotations

from app.mcp.ingredients import ingredients_create, ingredients_list
from app.mcp.recipes import (
    recipes_list,
    recipes_metadata,
    recipes_nutrition_search,
)


def test_recipes_list_runs() -> None:
    result = recipes_list()
    assert isinstance(result, list)


def test_recipes_metadata_runs() -> None:
    result = recipes_metadata()
    assert isinstance(result, dict)


def test_recipes_nutrition_search_runs() -> None:
    result = recipes_nutrition_search("egg", 5)
    assert isinstance(result, list)


def test_ingredients_list_runs() -> None:
    result = ingredients_list("", 5)
    assert isinstance(result, list)


def test_ingredients_create_runs() -> None:
    result = ingredients_create(name="Test Ingredient Z")
    assert isinstance(result, dict)
