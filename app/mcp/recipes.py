from __future__ import annotations

from typing import Any

from . import mcp
from ._helpers import _call_route, _settings

from app.api.recipes import (
    archive_recipe_route,
    create_metadata_item_route,
    estimate_recipe_nutrition_route,
    import_recipe_route,
    import_recipe_text_route,
    nutrition_match_route,
    nutrition_search_route,
    recipe_companion_drafts_route,
    recipe_detail_route,
    recipe_metadata_route,
    recipe_suggestion_draft_route,
    recipe_variation_draft_route,
    restore_recipe_route,
    save_recipe,
)
from app.db import session_scope
from app.schemas import (
    IngredientNutritionMatchRequest,
    ManagedListItemCreateRequest,
    RecipeCompanionDraftRequest,
    RecipeImportRequest,
    RecipePayload,
    RecipeSuggestionDraftRequest,
    RecipeTextImportRequest,
    RecipeVariationDraftRequest,
)
from app.services.presenters import recipes_payload
from app.services.recipes import get_recipe


@mcp.tool(description="List recipes in SimmerSmith.")
def recipes_list(
    include_archived: bool = False, cuisine: str = "", tags: list[str] | None = None
) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(
            lambda: recipes_payload(
                session,
                include_archived=include_archived,
                cuisine=cuisine,
                tags=tags or [],
            )
        )


@mcp.tool(description="Get one recipe by ID.")
def recipes_get(recipe_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: recipe_detail_route(recipe_id, session=session))


@mcp.tool(description="Create or update a recipe.")
def recipes_save(payload: RecipePayload) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: save_recipe(payload, session=session))


@mcp.tool(description="Import a recipe draft from a source URL.")
def recipes_import_from_url(url: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeImportRequest(url=url)
        return _call_route(
            lambda: import_recipe_route(payload, session=session).model_dump(mode="json")
        )


@mcp.tool(description="Import a recipe draft from extracted text, OCR, or pasted content.")
def recipes_import_from_text(
    text: str,
    title: str = "",
    source: str = "scan_import",
    source_label: str = "",
    source_url: str = "",
) -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeTextImportRequest(
            text=text,
            title=title,
            source=source,
            source_label=source_label,
            source_url=source_url,
        )
        return _call_route(
            lambda: import_recipe_text_route(payload, session=session).model_dump(mode="json")
        )


@mcp.tool(description="List recipe metadata including cuisines, tags, units, and templates.")
def recipes_metadata() -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: recipe_metadata_route(session=session))


@mcp.tool(description="Add a managed recipe metadata item such as a cuisine, tag, or unit.")
def recipes_add_metadata_item(kind: str, name: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = ManagedListItemCreateRequest(name=name)
        return _call_route(lambda: create_metadata_item_route(kind, payload, session=session))


@mcp.tool(description="Generate a recipe suggestion draft.")
def recipes_suggestion_draft(goal: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeSuggestionDraftRequest(goal=goal)
        return _call_route(
            lambda: recipe_suggestion_draft_route(payload, session=session, settings=_settings())
        )


@mcp.tool(description="Generate three companion recipe drafts for a recipe.")
def recipes_companion_drafts(recipe_id: str, focus: str = "sides_and_sauces") -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeCompanionDraftRequest(focus=focus)
        return _call_route(
            lambda: recipe_companion_drafts_route(
                recipe_id,
                payload,
                session=session,
                settings=_settings(),
            )
        )


@mcp.tool(description="Generate a recipe variation draft for an existing recipe.")
def recipes_variation_draft(recipe_id: str, goal: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeVariationDraftRequest(goal=goal)
        return _call_route(
            lambda: recipe_variation_draft_route(
                recipe_id,
                payload,
                session=session,
                settings=_settings(),
            )
        )


@mcp.tool(description="Estimate nutrition for a recipe payload.")
def recipes_nutrition_estimate(payload: RecipePayload) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: estimate_recipe_nutrition_route(payload, session=session))


@mcp.tool(description="Search the nutrition database by ingredient or food name.")
def recipes_nutrition_search(query: str = "", limit: int = 20) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: nutrition_search_route(q=query, limit=limit, session=session))


@mcp.tool(description="Save or update a nutrition-item match for an ingredient.")
def recipes_nutrition_match(
    ingredient_name: str, normalized_name: str | None, nutrition_item_id: str
) -> dict[str, Any]:
    with session_scope() as session:
        payload = IngredientNutritionMatchRequest(
            ingredient_name=ingredient_name,
            normalized_name=normalized_name,
            nutrition_item_id=nutrition_item_id,
        )
        return _call_route(lambda: nutrition_match_route(payload, session=session))


@mcp.tool(description="Archive a recipe.")
def recipes_archive(recipe_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: archive_recipe_route(recipe_id, session=session))


@mcp.tool(description="Restore an archived recipe.")
def recipes_restore(recipe_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: restore_recipe_route(recipe_id, session=session))


@mcp.tool(description="Delete a recipe permanently.")
def recipes_delete(recipe_id: str) -> dict[str, Any]:
    with session_scope() as session:
        recipe = get_recipe(session, recipe_id)
        if recipe is None:
            raise ValueError("Recipe not found")
        session.delete(recipe)
        return {"deleted": True, "recipe_id": recipe_id}
