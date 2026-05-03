"""Pick which store(s) to use for a grocery list.

The full optimization is bin-packing-with-minimums. We sidestep that
with a deterministic two-pass heuristic that's good enough for
real-world grocery lists (10-30 items, 4 candidate stores):

1. **Greedy single-store pass**: assign every item to its cheapest
   store. If exactly one store is used and its subtotal clears the
   delivery minimum, we're done — single-stop wins.
2. **Two-store retry**: if the greedy pass uses more stores than
   `max_stops`, OR a chosen store's subtotal is below its minimum,
   try every pair of stores and pick the one that minimizes
   (sum of cheapest-of-the-pair per item) + a per-stop penalty.

The penalty is configurable; default $5 per stop captures "driving
to a second store has a real cost beyond the dollar total".
"""
from __future__ import annotations

import logging
from collections import defaultdict
from dataclasses import dataclass
from itertools import combinations
from typing import Mapping


log = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class Candidate:
    """One per (item, store) pair: how much would it cost / fit there?"""
    store: str
    price: float
    available: bool
    product_name: str = ""


@dataclass(frozen=True, slots=True)
class Assignment:
    """Final per-item decision."""
    item_index: int
    store: str
    candidate: Candidate


@dataclass(frozen=True, slots=True)
class StoreSplit:
    assignments: list[Assignment]
    per_store_subtotals: dict[str, float]
    unassigned_indices: list[int]   # items no store could fulfil
    total: float


def split(
    candidates_by_item: list[list[Candidate]],
    *,
    minimums: Mapping[str, float],
    max_stops: int = 2,
    stop_penalty: float = 5.0,
) -> StoreSplit:
    """Compute the cheapest assignment of items to stores.

    `candidates_by_item[i]` is the list of `Candidate` rows the store
    handlers returned for item `i`. Pass an empty list for items no
    store could fulfil — they end up in `unassigned_indices`.

    `minimums[store]` is the per-store delivery minimum (default 0
    for stores not listed). When a store's subtotal would fall under
    its minimum, the heuristic tries to consolidate items elsewhere.
    """
    available_stores = sorted({
        c.store for cands in candidates_by_item for c in cands if c.available
    })

    greedy = _greedy_assignment(candidates_by_item)
    greedy_stores = {a.store for a in greedy.assignments}

    if (
        len(greedy_stores) <= max_stops
        and _meets_minimums(greedy, minimums)
    ):
        return greedy

    # Try every k-store combination up to max_stops; pick lowest cost
    # including the stop penalty.
    best: StoreSplit | None = None
    for k in range(1, max_stops + 1):
        for combo in combinations(available_stores, k):
            attempt = _restricted_assignment(candidates_by_item, set(combo))
            if not _meets_minimums(attempt, minimums):
                continue
            penalty = stop_penalty * len({a.store for a in attempt.assignments})
            if best is None or (attempt.total + penalty) < (best.total + stop_penalty * len({a.store for a in best.assignments})):
                best = attempt

    if best is None:
        # No combination meets minimums — return the greedy pass and
        # let the caller surface the under-minimum warning.
        log.warning("no store split met all minimums; returning greedy")
        return greedy
    return best


def _greedy_assignment(candidates_by_item: list[list[Candidate]]) -> StoreSplit:
    return _restricted_assignment(candidates_by_item, allowed=None)


def _restricted_assignment(
    candidates_by_item: list[list[Candidate]],
    allowed: set[str] | None,
) -> StoreSplit:
    """Assign every item to its cheapest available store from `allowed`
    (or any store when `allowed is None`)."""
    assignments: list[Assignment] = []
    unassigned: list[int] = []
    subtotals: dict[str, float] = defaultdict(float)
    for i, cands in enumerate(candidates_by_item):
        eligible = [
            c for c in cands
            if c.available and (allowed is None or c.store in allowed)
        ]
        if not eligible:
            unassigned.append(i)
            continue
        winner = min(eligible, key=lambda c: c.price)
        assignments.append(Assignment(item_index=i, store=winner.store, candidate=winner))
        subtotals[winner.store] += winner.price
    total = sum(a.candidate.price for a in assignments)
    return StoreSplit(
        assignments=assignments,
        per_store_subtotals=dict(subtotals),
        unassigned_indices=unassigned,
        total=round(total, 2),
    )


def _meets_minimums(split_: StoreSplit, minimums: Mapping[str, float]) -> bool:
    for store, subtotal in split_.per_store_subtotals.items():
        floor = minimums.get(store, 0.0)
        if floor and subtotal < floor:
            return False
    return True
