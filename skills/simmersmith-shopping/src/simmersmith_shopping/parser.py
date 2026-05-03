"""Parser for grocery item titles produced by the SimmerSmith iOS
RemindersService.swift `remindersTitle(for:)` formatter.

The titles look like `"<qty> <unit> <name>"` — e.g. `"2 cups flour"`,
`"1 pkg paper towels"`, `"3 ea avocados"`. Some titles drop the
quantity ("paper towels") or the unit ("3 lemons"). This parser
handles all three shapes plus mixed fractions like `"1 1/2 cups"`.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from fractions import Fraction


# Units that the iOS layer normalizes through. The skill only needs to
# RECOGNIZE these as units (so they don't end up as part of the name);
# downstream code treats them as opaque labels passed to retailer search.
KNOWN_UNITS: frozenset[str] = frozenset({
    "ct", "ea", "lb", "lbs", "oz", "fl oz", "gal", "cup", "cups",
    "tbsp", "tsp", "pkg", "package", "can", "bag", "bunch", "clove",
    "slice", "stick", "loaf", "pint", "quart", "qt", "ml", "l",
    "g", "kg", "dozen",
})

# Standalone fraction "3/4". Mixed forms ("1 3/4") are detected by
# peeking at adjacent tokens in `_take_quantity`.
_FRACTION_RE = re.compile(r"^\d+/\d+$")


@dataclass(frozen=True, slots=True)
class GroceryLine:
    raw_title: str
    quantity: float | None
    unit: str
    name: str
    completed: bool = False


def parse(title: str, *, completed: bool = False) -> GroceryLine:
    """Parse one Reminders title into structured `GroceryLine` data.

    Permissive — never raises. When the title doesn't fit the expected
    shape the whole text becomes the `name` with `quantity=None` and
    `unit=""`. Downstream code (store handlers) can still string-match
    for product candidates.
    """
    cleaned = title.strip()
    if not cleaned:
        return GroceryLine(raw_title=title, quantity=None, unit="", name="", completed=completed)

    parts = cleaned.split()
    quantity, head_consumed = _take_quantity(parts)
    rest = parts[head_consumed:]
    unit, head_consumed = _take_unit(rest)
    rest = rest[head_consumed:]
    name = " ".join(rest).strip()
    if not name and quantity is None and unit:
        # "cups" alone is degenerate — fall back to using the original
        # text as the name.
        name = cleaned
    return GroceryLine(
        raw_title=title,
        quantity=quantity,
        unit=unit,
        name=name,
        completed=completed,
    )


def _take_quantity(parts: list[str]) -> tuple[float | None, int]:
    if not parts:
        return None, 0
    head = parts[0]
    # "1 1/2" — peek at the next token.
    if len(parts) >= 2 and head.isdigit() and _FRACTION_RE.match(parts[1]):
        try:
            value = float(int(head)) + float(Fraction(parts[1]))
            return value, 2
        except ValueError:
            return None, 0
    if _FRACTION_RE.match(head):
        try:
            return float(Fraction(head)), 1
        except ValueError:
            return None, 0
    try:
        return float(head), 1
    except ValueError:
        return None, 0


def _take_unit(parts: list[str]) -> tuple[str, int]:
    if not parts:
        return "", 0
    # Try a 2-token unit first ("fl oz") then fall back to 1-token.
    if len(parts) >= 2:
        two = f"{parts[0].lower()} {parts[1].lower()}"
        if two in KNOWN_UNITS:
            return two, 2
    one = parts[0].lower()
    if one in KNOWN_UNITS:
        return one, 1
    return "", 0
