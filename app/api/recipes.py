from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy.orm import Session

from app.db import get_session
from app.schemas import (
    IngredientNutritionMatchOut,
    IngredientNutritionMatchRequest,
    ManagedListItemCreateRequest,
    ManagedListItemOut,
    NutritionItemOut,
    NutritionSummaryOut,
    RecipeImportRequest,
    RecipeMetadataOut,
    RecipeOut,
    RecipePayload,
    RecipeTextImportRequest,
)
from app.services.drafts import upsert_recipe
from app.services.managed_lists import create_item, metadata_payload
from app.services.nutrition import (
    calculate_recipe_nutrition,
    ingredient_nutrition_match_payload,
    nutrition_item_payload,
    save_ingredient_nutrition_match,
    search_nutrition_items,
)
from app.services.presenters import recipe_payload, recipes_payload
from app.services.recipe_import import import_recipe_from_text, import_recipe_from_url
from app.services.recipes import archive_recipe, get_recipe, restore_recipe


router = APIRouter(prefix="/api/recipes", tags=["recipes"])


def _with_nutrition_summary(session: Session, recipe: RecipePayload) -> RecipePayload:
    recipe.nutrition_summary = NutritionSummaryOut(
        **calculate_recipe_nutrition(
            session,
            [
                {
                    "ingredient_name": ingredient.ingredient_name,
                    "normalized_name": ingredient.normalized_name,
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
) -> list[dict[str, object]]:
    return recipes_payload(
        session,
        include_archived=include_archived,
        cuisine=cuisine,
        tags=tag or [],
    )


@router.get("/metadata", response_model=RecipeMetadataOut)
def recipe_metadata_route(session: Session = Depends(get_session)) -> dict[str, object]:
    return metadata_payload(session)


@router.post("/metadata/{kind}", response_model=ManagedListItemOut)
def create_metadata_item_route(
    kind: str,
    payload: ManagedListItemCreateRequest,
    session: Session = Depends(get_session),
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
def recipe_detail_route(recipe_id: str, session: Session = Depends(get_session)) -> dict[str, object]:
    recipe = get_recipe(session, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return recipe_payload(session, recipe)


@router.post("", response_model=RecipeOut)
def save_recipe(payload: RecipePayload, session: Session = Depends(get_session)) -> dict[str, object]:
    try:
        recipe = upsert_recipe(session, payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session.commit()
    refreshed = get_recipe(session, recipe.id)
    return recipe_payload(session, refreshed) if refreshed else {}


@router.post("/import-from-url", response_model=RecipePayload)
def import_recipe_route(payload: RecipeImportRequest, session: Session = Depends(get_session)) -> RecipePayload:
    try:
        recipe = import_recipe_from_url(payload.url)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _with_nutrition_summary(session, recipe)


@router.post("/import-from-text", response_model=RecipePayload)
def import_recipe_text_route(
    payload: RecipeTextImportRequest,
    session: Session = Depends(get_session),
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


@router.post("/nutrition/estimate", response_model=NutritionSummaryOut)
def estimate_recipe_nutrition_route(
    payload: RecipePayload,
    session: Session = Depends(get_session),
) -> dict[str, object]:
    summary = calculate_recipe_nutrition(
        session,
        [
            {
                "ingredient_name": ingredient.ingredient_name,
                "normalized_name": ingredient.normalized_name,
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
    limit: int = 20,
    session: Session = Depends(get_session),
) -> list[dict[str, object]]:
    return [nutrition_item_payload(item) for item in search_nutrition_items(session, q, limit=limit)]


@router.post("/nutrition/matches", response_model=IngredientNutritionMatchOut)
def nutrition_match_route(
    payload: IngredientNutritionMatchRequest,
    session: Session = Depends(get_session),
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
def archive_recipe_route(recipe_id: str, session: Session = Depends(get_session)) -> dict[str, object]:
    recipe = get_recipe(session, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    archive_recipe(recipe)
    session.commit()
    refreshed = get_recipe(session, recipe_id)
    return recipe_payload(session, refreshed) if refreshed else {}


@router.post("/{recipe_id}/restore", response_model=RecipeOut)
def restore_recipe_route(recipe_id: str, session: Session = Depends(get_session)) -> dict[str, object]:
    recipe = get_recipe(session, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    restore_recipe(recipe)
    session.commit()
    refreshed = get_recipe(session, recipe_id)
    return recipe_payload(session, refreshed) if refreshed else {}


@router.delete("/{recipe_id}", status_code=204)
def delete_recipe_route(recipe_id: str, session: Session = Depends(get_session)) -> Response:
    recipe = get_recipe(session, recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="Recipe not found")
    session.delete(recipe)
    session.commit()
    return Response(status_code=204)
