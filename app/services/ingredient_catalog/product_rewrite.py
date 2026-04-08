from __future__ import annotations

import re

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import (
    BaseIngredient,
    GroceryItem,
    IngredientVariation,
    RecipeIngredient,
    WeekMealIngredient,
)

from .shared import (
    LEADING_QUANTITY_PATTERN,
    MARKETING_PREFIXES,
    PACKAGING_TOKENS,
    PACKAGE_SIZE_PATTERN,
    ProductLikeRewritePlan,
    ProductLikeRewriteResult,
    VariationCandidate,
    _active_base_by_normalized_name,
    _active_variation_by_normalized_name,
    _source_payload,
    get_base_ingredient,
    normalize_name,
)
from .variation import (
    create_or_update_variation,
    ensure_base_ingredient,
    ingredient_preference_for_base,
    merge_base_ingredients,
)


def cleaned_base_ingredient_name(
    name: str, *, source_name: str = "", source_payload: dict[str, object] | None = None
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
