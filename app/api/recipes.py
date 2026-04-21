from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings
from app.db import get_session
from app.models import AIRun
from app.schemas import (
    RecipeAIDraftOptionOut,
    IngredientNutritionMatchOut,
    IngredientNutritionMatchRequest,
    IngredientSubstituteRequest,
    IngredientSubstituteResponse,
    ManagedListItemCreateRequest,
    ManagedListItemOut,
    NutritionItemOut,
    NutritionSummaryOut,
    RecipeImportRequest,
    RecipeAIOptionsOut,
    RecipeIngredientPayload,
    RecipeMetadataOut,
    RecipeOut,
    RecipePayload,
    RecipeAIDraftOut,
    RecipeCompanionDraftRequest,
    RecipeTextImportRequest,
    RecipeSuggestionDraftRequest,
    RecipeVariationDraftRequest,
)
from app.services.ai import profile_settings_map, resolve_ai_execution_target
from app.services.drafts import resolution_status_override, upsert_recipe
from app.services.ingredient_catalog import resolve_ingredient
from app.services.managed_lists import create_item, metadata_payload
from app.services.nutrition import (
    calculate_recipe_nutrition,
    ingredient_nutrition_match_payload,
    nutrition_item_payload,
    save_ingredient_nutrition_match,
    search_nutrition_items,
)
from app.services.presenters import recipe_payload, recipes_payload
from app.services.recipe_ai import build_companion_drafts, build_suggestion_draft, build_variation_draft
from app.services.substitution_ai import suggest_substitutions
from app.services.recipe_import import import_recipe_from_text, import_recipe_from_url
from app.services.recipes import archive_recipe, get_recipe, list_recipes, restore_recipe


router = APIRouter(prefix="/api/recipes", tags=["recipes"])


def _with_nutrition_summary(session: Session, recipe: RecipePayload) -> RecipePayload:
    resolved_ingredients = []
    for ingredient in recipe.ingredients:
        resolved = resolve_ingredient(
            session,
            ingredient_name=ingredient.ingredient_name,
            normalized_name=ingredient.normalized_name,
            quantity=ingredient.quantity,
            unit=ingredient.unit,
            prep=ingredient.prep,
            category=ingredient.category,
            notes=ingredient.notes,
            base_ingredient_id=ingredient.base_ingredient_id,
            ingredient_variation_id=ingredient.ingredient_variation_id,
            resolution_status=resolution_status_override(ingredient),
        )
        resolved_ingredients.append(
            RecipeIngredientPayload.model_validate({"ingredient_id": ingredient.ingredient_id, **resolved.as_payload()})
        )
    recipe.ingredients = resolved_ingredients
    recipe.nutrition_summary = NutritionSummaryOut(
        **calculate_recipe_nutrition(
            session,
            [
                {
                    "ingredient_name": ingredient.ingredient_name,
                    "normalized_name": ingredient.normalized_name,
                    "base_ingredient_id": ingredient.base_ingredient_id,
                    "ingredient_variation_id": ingredient.ingredient_variation_id,
                    "quantity": ingredient.quantity,
                    "unit": ingredient.unit,
                }
                for ingredient in recipe.ingredients
            ],
            recipe.servings,
        ).as_payload()
    )
    return recipe


@router.get("", response_model=list[RecipeOut])
def list_recipes_route(
    include_archived: bool = False,
    cuisine: str = "",
    tag: list[str] | None = None,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    return recipes_payload(
        session,
        user_id=current_user.id,
        include_archived=include_archived,
        cuisine=cuisine,
        tags=tag or [],
    )


@router.get("/metadata", response_model=RecipeMetadataOut)
def recipe_metadata_route(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    return metadata_payload(session)


@router.post("/metadata/{kind}", response_model=ManagedListItemOut)
def create_metadata_item_route(
    kind: str,
    payload: ManagedListItemCreateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    if kind not in {"cuisine", "tag", "unit"}:
        raise HTTPException(status_code=404, detail="Unsupported managed list")
    try:
        item = create_item(session, kind, payload.name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    return {
        "item_id": item.id,
        "kind": item.kind,
        "name": item.name,
        "normalized_name": item.normalized_name,
        "updated_at": item.updated_at,
    }


@router.get("/{recipe_id}", response_model=RecipeOut)
def recipe_detail_route(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    recipe = get_recipe(session, current_user.id, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return recipe_payload(session, recipe)


@router.post("", response_model=RecipeOut)
def save_recipe(
    payload: RecipePayload,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    try:
        recipe = upsert_recipe(session, payload, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    refreshed = get_recipe(session, current_user.id, recipe.id)
    return recipe_payload(session, refreshed) if refreshed else {}


@router.post("/import-from-url", response_model=RecipePayload)
def import_recipe_route(
    payload: RecipeImportRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> RecipePayload:
    try:
        recipe = import_recipe_from_url(payload.url)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _with_nutrition_summary(session, recipe)


@router.post("/import-from-html", response_model=RecipePayload)
def import_recipe_html_route(
    payload: RecipeTextImportRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> RecipePayload:
    """Import a recipe from raw HTML (extracted by an in-app browser)."""
    from app.services.recipe_import import parse_recipe_html
    try:
        recipe = parse_recipe_html(payload.text, payload.source_url or "")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if payload.source:
        recipe.source = payload.source
    if payload.source_label:
        recipe.source_label = payload.source_label
    if payload.source_url:
        recipe.source_url = payload.source_url
    return _with_nutrition_summary(session, recipe)


@router.post("/import-from-text", response_model=RecipePayload)
def import_recipe_text_route(
    payload: RecipeTextImportRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> RecipePayload:
    try:
        recipe = import_recipe_from_text(
            payload.text,
            title=payload.title,
            source=payload.source,
            source_label=payload.source_label,
            source_url=payload.source_url,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _with_nutrition_summary(session, recipe)


@router.post("/ai/suggestion-draft", response_model=RecipeAIDraftOut)
def recipe_suggestion_draft_route(
    payload: RecipeSuggestionDraftRequest,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    saved_recipes = [
        RecipePayload.model_validate(recipe_payload(session, recipe))
        for recipe in list_recipes(session, current_user.id, include_archived=False)
    ]
    try:
        draft, rationale, resolved_goal = build_suggestion_draft(saved_recipes, goal=payload.goal)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    draft = _with_nutrition_summary(session, draft)
    user_settings = profile_settings_map(session, current_user.id)
    execution_target = resolve_ai_execution_target(settings, user_settings)
    if execution_target is None:
        model_name = "heuristic-suggestion-v1"
    else:
        model_name = execution_target.provider_name or execution_target.mcp_server_name or "heuristic-suggestion-v1"
    session.add(
        AIRun(
            user_id=current_user.id,
            week_id=None,
            run_type="recipe_suggestion",
            model=model_name,
            prompt=payload.goal,
            status="completed",
            request_payload=payload.model_dump_json(),
            response_payload=RecipeAIDraftOut(goal=resolved_goal, rationale=rationale, draft=draft).model_dump_json(),
        )
    )
    session.commit()
    return RecipeAIDraftOut(goal=resolved_goal, rationale=rationale, draft=draft).model_dump()


@router.post("/{recipe_id}/ai/companion-drafts", response_model=RecipeAIOptionsOut)
def recipe_companion_drafts_route(
    recipe_id: str,
    payload: RecipeCompanionDraftRequest,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    recipe = get_recipe(session, current_user.id, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")

    anchor_payload = RecipePayload.model_validate(recipe_payload(session, recipe))
    draft_options, rationale, resolved_goal = build_companion_drafts(anchor_payload, focus=payload.focus)
    response_options = [
        RecipeAIDraftOptionOut(
            option_id=option_id,
            label=label,
            rationale=option_rationale,
            draft=_with_nutrition_summary(session, draft),
        )
        for option_id, label, option_rationale, draft in draft_options
    ]

    response_payload = RecipeAIOptionsOut(goal=resolved_goal, rationale=rationale, options=response_options)
    user_settings = profile_settings_map(session, current_user.id)
    execution_target = resolve_ai_execution_target(settings, user_settings)
    if execution_target is None:
        model_name = "heuristic-companion-v1"
    else:
        model_name = execution_target.provider_name or execution_target.mcp_server_name or "heuristic-companion-v1"
    session.add(
        AIRun(
            user_id=current_user.id,
            week_id=None,
            run_type="recipe_companion",
            model=model_name,
            prompt=payload.focus,
            status="completed",
            request_payload=payload.model_dump_json(),
            response_payload=response_payload.model_dump_json(),
        )
    )
    session.commit()
    return response_payload.model_dump()


@router.post("/{recipe_id}/ai/variation-draft", response_model=RecipeAIDraftOut)
def recipe_variation_draft_route(
    recipe_id: str,
    payload: RecipeVariationDraftRequest,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    recipe = get_recipe(session, current_user.id, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")

    base_payload = RecipePayload.model_validate(recipe_payload(session, recipe))
    draft, rationale, resolved_goal = build_variation_draft(base_payload, goal=payload.goal)
    draft = _with_nutrition_summary(session, draft)

    user_settings = profile_settings_map(session, current_user.id)
    execution_target = resolve_ai_execution_target(settings, user_settings)
    if execution_target is None:
        model_name = "heuristic-variation-v1"
    else:
        model_name = execution_target.provider_name or execution_target.mcp_server_name or "heuristic-variation-v1"
    session.add(
        AIRun(
            user_id=current_user.id,
            week_id=None,
            run_type="recipe_variation",
            model=model_name,
            prompt=payload.goal,
            status="completed",
            request_payload=payload.model_dump_json(),
            response_payload=RecipeAIDraftOut(goal=resolved_goal, rationale=rationale, draft=draft).model_dump_json(),
        )
    )
    session.commit()
    return RecipeAIDraftOut(goal=resolved_goal, rationale=rationale, draft=draft).model_dump()


@router.post(
    "/{recipe_id}/ai/substitute",
    response_model=IngredientSubstituteResponse,
)
def recipe_ingredient_substitute_route(
    recipe_id: str,
    payload: IngredientSubstituteRequest,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    """Ask the AI for 3-5 substitutes for a single ingredient in a recipe.

    The picked substitute is applied client-side (iOS) by re-upserting the
    whole recipe — this endpoint only returns suggestions and never
    mutates the recipe itself. Keeps the preview flow cheap.
    """
    from app.models import IngredientPreference
    from app.services.ingredient_catalog.variation import list_ingredient_preferences

    recipe = get_recipe(session, current_user.id, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")

    target = next(
        (ing for ing in recipe.ingredients if ing.id == payload.ingredient_id),
        None,
    )
    if target is None:
        raise HTTPException(
            status_code=404,
            detail="Ingredient not found in this recipe.",
        )

    user_settings = profile_settings_map(session, current_user.id)
    preferences: list[IngredientPreference] = list_ingredient_preferences(session, current_user.id)

    try:
        response = suggest_substitutions(
            recipe=recipe,
            target_ingredient=target,
            user_preferences=preferences,
            settings=settings,
            user_settings=user_settings,
            hint=payload.hint,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    session.add(
        AIRun(
            user_id=current_user.id,
            week_id=None,
            run_type="recipe_substitute",
            model="substitution-v1",
            prompt=f"{target.ingredient_name} in {recipe.name}",
            status="completed",
            request_payload=payload.model_dump_json(),
            response_payload=response.model_dump_json(),
        )
    )
    session.commit()
    return response.model_dump()


@router.post("/nutrition/estimate", response_model=NutritionSummaryOut)
def estimate_recipe_nutrition_route(
    payload: RecipePayload,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    summary = calculate_recipe_nutrition(
        session,
        [
            {
                "ingredient_name": ingredient.ingredient_name,
                "normalized_name": ingredient.normalized_name,
                "base_ingredient_id": ingredient.base_ingredient_id,
                "ingredient_variation_id": ingredient.ingredient_variation_id,
                "quantity": ingredient.quantity,
                "unit": ingredient.unit,
            }
            for ingredient in payload.ingredients
        ],
        payload.servings,
    )
    return summary.as_payload()


@router.get("/nutrition/search", response_model=list[NutritionItemOut])
def nutrition_search_route(
    q: str = "",
    limit: int = Query(default=20, ge=1, le=50),
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    return [nutrition_item_payload(item) for item in search_nutrition_items(session, q, limit=limit)]


@router.post("/nutrition/matches", response_model=IngredientNutritionMatchOut)
def nutrition_match_route(
    payload: IngredientNutritionMatchRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    try:
        match = save_ingredient_nutrition_match(
            session,
            ingredient_name=payload.ingredient_name,
            normalized_name=payload.normalized_name,
            nutrition_item_id=payload.nutrition_item_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    session.refresh(match)
    return ingredient_nutrition_match_payload(match)


@router.post("/{recipe_id}/archive", response_model=RecipeOut)
def archive_recipe_route(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    recipe = get_recipe(session, current_user.id, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    archive_recipe(recipe)
    session.commit()
    refreshed = get_recipe(session, current_user.id, recipe_id)
    return recipe_payload(session, refreshed) if refreshed else {}


@router.post("/{recipe_id}/restore", response_model=RecipeOut)
def restore_recipe_route(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    recipe = get_recipe(session, current_user.id, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    restore_recipe(recipe)
    session.commit()
    refreshed = get_recipe(session, current_user.id, recipe_id)
    return recipe_payload(session, refreshed) if refreshed else {}


@router.delete("/{recipe_id}", status_code=204)
def delete_recipe_route(
    recipe_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    recipe = get_recipe(session, current_user.id, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    session.delete(recipe)
    session.commit()
    return Response(status_code=204)
