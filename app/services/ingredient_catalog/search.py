from __future__ import annotations

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.models import (
    BaseIngredient,
    GroceryItem,
    IngredientPreference,
    IngredientVariation,
    Recipe,
    RecipeIngredient,
)

from .product_rewrite import is_product_like_base_ingredient
from .shared import MAX_LINKED_ITEMS, IngredientUsageSummary, normalize_name


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
    household_id: str | None = None,
) -> list[BaseIngredient]:
    statement = select(BaseIngredient)
    if not include_archived:
        statement = statement.where(
            BaseIngredient.archived_at.is_(None), BaseIngredient.active.is_(True)
        )
    # M25: visibility filter. Approved (global) is always visible; the
    # caller's own household-owned rows are also visible regardless of
    # `submission_status`. Other households' submitted/household_only
    # rows stay hidden until an admin promotes them to approved.
    if household_id is not None:
        statement = statement.where(
            or_(
                BaseIngredient.submission_status == "approved",
                BaseIngredient.household_id == household_id,
            )
        )
    else:
        # No household context (e.g. anonymous internal callers like
        # the seed script) — restrict to approved rows only.
        statement = statement.where(BaseIngredient.submission_status == "approved")
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
