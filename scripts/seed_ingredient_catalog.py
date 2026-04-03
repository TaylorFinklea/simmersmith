from __future__ import annotations

import argparse
from pathlib import Path

from app.config import get_settings
from app.db import session_scope
from app.services.bootstrap import run_migrations
from app.services.ingredient_catalog import ensure_catalog_defaults, normalize_product_like_base_ingredients
from app.services.ingredient_ingest import (
    OPEN_FOOD_FACTS_DEFAULT_TERMS,
    USDA_DEFAULT_SEED_TERMS,
    ingest_open_food_facts_terms,
    prune_usda_seed_rows,
    ingest_usda_terms,
    seed_terms_from_file,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Seed the SimmerSmith ingredient catalog from external food datasets.")
    parser.add_argument("--usda-api-key", default="", help="USDA FoodData Central API key. Defaults to SIMMERSMITH_USDA_API_KEY, then DEMO_KEY.")
    parser.add_argument("--no-usda", action="store_true", help="Skip USDA ingest.")
    parser.add_argument("--include-open-food-facts", action="store_true", help="Also ingest branded products from Open Food Facts.")
    parser.add_argument("--terms-file", default="", help="Optional newline-delimited file of ingredient/product search terms.")
    parser.add_argument("--page-size", type=int, default=25, help="Results per search term page.")
    parser.add_argument("--max-pages", type=int, default=1, help="Pages to fetch per term for USDA.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    run_migrations()
    settings = get_settings()
    usda_api_key = args.usda_api_key or settings.usda_api_key or "DEMO_KEY"
    terms_file = Path(args.terms_file).expanduser() if args.terms_file else None
    seed_terms = seed_terms_from_file(terms_file) if terms_file and terms_file.exists() else USDA_DEFAULT_SEED_TERMS

    with session_scope() as session:
        ensure_catalog_defaults(session)

        if not args.no_usda:
            result = ingest_usda_terms(
                session,
                api_key=usda_api_key,
                terms=seed_terms,
                page_size=args.page_size,
                max_pages=args.max_pages,
            )
            print(
                f"{result.source_label}: processed {result.bases_created_or_updated} base ingredient hits "
                f"with {result.skipped_terms} skipped term/page requests into {settings.db_path}"
            )
            archived_count = prune_usda_seed_rows(session, allowed_terms=seed_terms)
            print(f"{result.source_label}: archived {archived_count} noisy live seed rows not in the curated term set")

        if args.include_open_food_facts:
            off_terms = seed_terms if terms_file else OPEN_FOOD_FACTS_DEFAULT_TERMS
            result = ingest_open_food_facts_terms(
                session,
                terms=off_terms,
                page_size=args.page_size,
            )
            print(
                f"{result.source_label}: processed {result.bases_created_or_updated} bases and "
                f"{result.variations_created_or_updated} product variations with {result.skipped_terms} skipped requests "
                f"into {settings.db_path}"
            )

        normalized_count = normalize_product_like_base_ingredients(session)
        print(f"Catalog cleanup: normalized {normalized_count} product-like base ingredient rows into cleaner generic bases")


if __name__ == "__main__":
    main()
