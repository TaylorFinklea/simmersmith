from __future__ import annotations

import re
from fractions import Fraction

from app.schemas import RecipeIngredientPayload
from app.services.grocery import normalize_name

from .common import clean_text, clean_text_line

JUNK_INGREDIENT_RE = re.compile(r"^(ingredients?|instructions?|directions?|method|for the .+)$", re.IGNORECASE)
QUANTITY_RE = re.compile(
    r"^(?P<quantity>(?:\d+\s+\d+/\d+)|(?:\d+-\d+/\d+)|(?:\d+/\d+)|(?:\d+(?:\.\d+)?))\b"
)
PACKAGE_NOTE_RE = re.compile(r"^\((?P<note>[^)]*?\d[^)]*)\)\s*")

FRACTION_CHAR_MAP = {
    "¼": "1/4",
    "½": "1/2",
    "¾": "3/4",
    "⅐": "1/7",
    "⅑": "1/9",
    "⅒": "1/10",
    "⅓": "1/3",
    "⅔": "2/3",
    "⅕": "1/5",
    "⅖": "2/5",
    "⅗": "3/5",
    "⅘": "4/5",
    "⅙": "1/6",
    "⅚": "5/6",
    "⅛": "1/8",
    "⅜": "3/8",
    "⅝": "5/8",
    "⅞": "7/8",
}

UNIT_ALIASES = {
    "teaspoon": "tsp",
    "teaspoons": "tsp",
    "tsp": "tsp",
    "tsp.": "tsp",
    "tablespoon": "tbsp",
    "tablespoons": "tbsp",
    "tbsp": "tbsp",
    "tbsp.": "tbsp",
    "cup": "cup",
    "cups": "cup",
    "fluid ounce": "fl oz",
    "fluid ounces": "fl oz",
    "fl oz": "fl oz",
    "fl. oz.": "fl oz",
    "ounce": "oz",
    "ounces": "oz",
    "oz": "oz",
    "oz.": "oz",
    "pound": "lb",
    "pounds": "lb",
    "lb": "lb",
    "lb.": "lb",
    "lbs": "lb",
    "lbs.": "lb",
    "can": "can",
    "cans": "can",
    "bag": "bag",
    "bags": "bag",
    "bunch": "bunch",
    "bunches": "bunch",
    "clove": "clove",
    "cloves": "clove",
    "package": "pkg",
    "packages": "pkg",
    "pkg": "pkg",
    "pkg.": "pkg",
    "slice": "slice",
    "slices": "slice",
    "jar": "jar",
    "jars": "jar",
    "bottle": "bottle",
    "bottles": "bottle",
}

LEADING_PREP_PHRASES = (
    "room temperature",
    "room-temperature",
    "lukewarm",
    "melted",
    "softened",
    "thawed",
    "beaten",
    "warm",
    "cold",
)

PREP_KEYWORDS = {
    "chopped",
    "diced",
    "drained",
    "grated",
    "halved",
    "lukewarm",
    "mashed",
    "melted",
    "minced",
    "peeled",
    "rinsed",
    "room temperature",
    "room-temperature",
    "shredded",
    "sliced",
    "softened",
    "thawed",
    "trimmed",
    "warm",
    "cold",
    "beaten",
    "crushed",
}

NOTE_PHRASES = (
    "to taste",
    "for serving",
    "for garnish",
    "plus more",
    "plus extra",
    "optional",
    "divided",
)

SORTED_UNIT_ALIASES = sorted(UNIT_ALIASES.items(), key=lambda item: (-len(item[0]), item[0]))

CATEGORY_KEYWORDS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("Condiments", ("mustard", "bbq sauce", "barbecue sauce", "ketchup", "mayo", "mayonnaise", "vinegar", "hot sauce", "soy sauce", "tamari")),
    ("Pantry", ("sugar", "salt", "pepper", "flour", "rice", "pasta", "spaghetti", "breadcrumbs", "rub", "seasoning", "sauce", "broth", "stock", "oil")),
    ("Dairy", ("milk", "butter", "cream", "cheese", "yogurt", "sour cream")),
    ("Produce", ("onion", "garlic", "lemon", "lime", "pepper", "peppers", "tomato", "tomatoes", "lettuce", "spinach", "broccoli", "carrot", "carrots", "banana", "bananas", "apple", "apples")),
    ("Meat", ("beef", "roast", "brisket", "steak", "pork", "sausage", "bacon", "chicken", "turkey", "lamb")),
    ("Seafood", ("salmon", "shrimp", "fish", "tuna", "crab", "lobster", "scallop")),
)


def extract_ingredient_lines(value) -> list[str]:
    items = value if isinstance(value, list) else [value]
    cleaned: list[str] = []
    seen: set[str] = set()
    for item in items:
        text = clean_text(item)
        if not text or JUNK_INGREDIENT_RE.match(text):
            continue
        key = text.lower()
        if key in seen:
            continue
        seen.add(key)
        cleaned.append(text)
    return cleaned


def normalize_fraction_text(text: str) -> str:
    normalized = text
    for character, replacement in FRACTION_CHAR_MAP.items():
        normalized = re.sub(rf"(?P<whole>\d){re.escape(character)}", rf"\g<whole> {replacement}", normalized)
        normalized = normalized.replace(character, replacement)
    normalized = re.sub(r"(\d+)-(\d+/\d+)", r"\1 \2", normalized)
    normalized = re.sub(r"\s+", " ", normalized)
    return normalized.strip()


def parse_quantity_text(value: str) -> float | None:
    text = normalize_fraction_text(clean_text_line(value))
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        pass

    mixed_match = re.fullmatch(r"(\d+)\s+(\d+/\d+)", text)
    if mixed_match:
        return float(int(mixed_match.group(1)) + Fraction(mixed_match.group(2)))

    fraction_match = re.fullmatch(r"\d+/\d+", text)
    if fraction_match:
        return float(Fraction(text))

    return None


def consume_quantity_prefix(line: str) -> tuple[float | None, str]:
    text = normalize_fraction_text(line)
    match = QUANTITY_RE.match(text)
    if not match:
        return None, line.strip()

    quantity_value = parse_quantity_text(match.group("quantity"))
    if quantity_value is None:
        return None, line.strip()
    return quantity_value, text[match.end():].strip()


def consume_package_note_prefix(line: str) -> tuple[str, str]:
    match = PACKAGE_NOTE_RE.match(line)
    if not match:
        return "", line.strip()
    return clean_text_line(match.group("note")), line[match.end():].strip()


def consume_unit_prefix(line: str) -> tuple[str, str]:
    lowered = line.lower().strip()
    for alias, canonical in SORTED_UNIT_ALIASES:
        if not lowered.startswith(alias):
            continue
        remainder = lowered[len(alias):]
        if remainder and remainder[0].isalnum():
            continue
        return canonical, line[len(alias):].strip()
    return "", line.strip()


def classify_modifier(text: str) -> tuple[str, str]:
    cleaned = clean_text_line(text)
    lowered = cleaned.lower()
    if not cleaned:
        return "", ""
    if any(phrase in lowered for phrase in NOTE_PHRASES):
        return "notes", cleaned
    if any(keyword in lowered for keyword in PREP_KEYWORDS):
        return "prep", cleaned
    return "notes", cleaned


def split_top_level_segments(text: str, separator: str = ",") -> list[str]:
    segments: list[str] = []
    current: list[str] = []
    depth = 0
    for character in text:
        if character == "(":
            depth += 1
        elif character == ")" and depth > 0:
            depth -= 1
        if character == separator and depth == 0:
            segment = clean_text_line("".join(current))
            if segment:
                segments.append(segment)
            current = []
            continue
        current.append(character)
    tail = clean_text_line("".join(current))
    if tail:
        segments.append(tail)
    return segments


def consume_inline_parenthetical_notes(line: str) -> tuple[str, str, str]:
    cleaned = clean_text_line(line)
    if "(" not in cleaned:
        return cleaned, "", ""

    remaining_chars: list[str] = []
    current_note: list[str] = []
    note_parts: list[str] = []
    prep_parts: list[str] = []
    depth = 0

    for character in cleaned:
        if character == "(":
            if depth == 0:
                current_note = []
            else:
                current_note.append(character)
            depth += 1
            continue
        if character == ")" and depth > 0:
            depth -= 1
            if depth == 0:
                field, value = classify_modifier("".join(current_note))
                if field == "prep" and value:
                    prep_parts.append(value)
                elif value:
                    note_parts.append(value)
                continue
            current_note.append(character)
            continue
        if depth > 0:
            current_note.append(character)
        else:
            remaining_chars.append(character)

    remaining = clean_text_line("".join(remaining_chars))
    return remaining, ", ".join(dict.fromkeys(prep_parts)), "; ".join(dict.fromkeys(note_parts))


def split_leading_prep(line: str) -> tuple[str, str]:
    cleaned = clean_text_line(line)
    lowered = cleaned.lower()
    for phrase in LEADING_PREP_PHRASES:
        if not lowered.startswith(phrase):
            continue
        remainder = cleaned[len(phrase):].strip(" ,-")
        if remainder:
            return phrase.replace("-", " "), remainder
    return "", cleaned


def split_modifier_suffixes(line: str) -> tuple[str, str, str]:
    cleaned = clean_text_line(line)
    parts = split_top_level_segments(cleaned)
    if not parts:
        return "", "", ""

    ingredient_name = parts[0]
    prep_parts: list[str] = []
    note_parts: list[str] = []
    for part in parts[1:]:
        field, value = classify_modifier(part)
        if field == "prep":
            prep_parts.append(value)
        elif value:
            note_parts.append(value)

    lowered_name = ingredient_name.lower()
    for phrase in NOTE_PHRASES:
        if lowered_name.endswith(f" {phrase}"):
            ingredient_name = ingredient_name[: -len(phrase)].strip(" ,-")
            note_parts.insert(0, phrase)
            break

    return ingredient_name, ", ".join(dict.fromkeys(prep_parts)), "; ".join(dict.fromkeys(note_parts))


def infer_ingredient_category(ingredient_name: str, *, unit: str = "", notes: str = "") -> str:
    haystack = normalize_name(" ".join(part for part in [ingredient_name, notes] if part))
    if not haystack:
        return ""
    for category, keywords in CATEGORY_KEYWORDS:
        if any(keyword in haystack for keyword in keywords):
            return category
    if unit in {"lb", "oz"} and any(term in haystack for term in ("roast", "meat", "beef", "pork", "chicken", "turkey")):
        return "Meat"
    return ""


def parse_ingredient_line(line: str) -> RecipeIngredientPayload:
    raw_line = clean_text_line(line)
    quantity, remainder = consume_quantity_prefix(raw_line)
    package_note = ""
    unit = ""

    if quantity is not None:
        package_note, remainder = consume_package_note_prefix(remainder)
        unit, remainder = consume_unit_prefix(remainder)

    remainder, parenthetical_prep, parenthetical_notes = consume_inline_parenthetical_notes(remainder)
    ingredient_name, prep, notes = split_modifier_suffixes(remainder)
    leading_prep, ingredient_name = split_leading_prep(ingredient_name)
    if leading_prep:
        prep = ", ".join(part for part in [leading_prep, prep] if part)
    if parenthetical_prep:
        prep = ", ".join(part for part in [prep, parenthetical_prep] if part)

    ingredient_name = clean_text_line(ingredient_name)
    combined_notes = "; ".join(part for part in [package_note, parenthetical_notes, notes] if part)

    if not ingredient_name:
        ingredient_name = raw_line
        quantity = None
        unit = ""
        prep = ""
        combined_notes = ""

    normalized_name = normalize_name(ingredient_name)
    return RecipeIngredientPayload(
        ingredient_name=ingredient_name,
        normalized_name=normalized_name or None,
        quantity=quantity,
        unit=unit,
        prep=prep,
        category=infer_ingredient_category(ingredient_name, unit=unit, notes=combined_notes),
        notes=combined_notes,
    )


def ingredient_payloads_from_lines(lines: list[str]) -> list[RecipeIngredientPayload]:
    return [parse_ingredient_line(line) for line in lines]
