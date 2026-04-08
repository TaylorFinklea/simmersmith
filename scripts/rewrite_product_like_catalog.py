from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from app.db import session_scope  # noqa: E402 — sys.path set above
from app.services.bootstrap import run_migrations  # noqa: E402
from app.services.ingredient_catalog import (  # noqa: E402
    apply_product_like_base_rewrites,
    plan_product_like_base_rewrites,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rewrite product-like base ingredients into generic bases plus suggested variations when warranted."
    )
    parser.add_argument("--apply", action="store_true", help="Apply the rewrite instead of returning a dry-run report.")
    parser.add_argument("--limit", type=int, default=None, help="Optional maximum number of product-like base rows to inspect.")
    parser.add_argument("--output", default="", help="Optional path to write the JSON report.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    run_migrations()
    with session_scope() as session:
        plans = plan_product_like_base_rewrites(session, limit=args.limit)
        payload: dict[str, object] = {
            "mode": "apply" if args.apply else "dry-run",
            "summary": {
                "total_candidates": len(plans),
                "actionable_count": sum(1 for plan in plans if plan.skip_reason is None and plan.merge_base),
                "skipped_count": sum(1 for plan in plans if plan.skip_reason is not None or not plan.merge_base),
            },
            "plans": [plan.as_payload() for plan in plans],
        }
        if args.apply:
            result = apply_product_like_base_rewrites(session, plans=plans)
            payload["summary"] = result.as_payload()

    rendered = json.dumps(payload, indent=2, sort_keys=True, default=str)
    if args.output:
        Path(args.output).expanduser().write_text(rendered + "\n")
    print(rendered)


if __name__ == "__main__":
    main()
