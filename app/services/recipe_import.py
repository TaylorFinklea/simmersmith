from __future__ import annotations

import json
import re
from fractions import Fraction
from html import unescape
from html.parser import HTMLParser
from typing import Any
from urllib import parse as urllib_parse
from urllib import request as urllib_request

from app.schemas import RecipeIngredientPayload, RecipePayload, RecipeStepPayload
from app.services.grocery import normalize_name


SCRIPT_RE = re.compile(
    r"<script[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>",
    re.IGNORECASE | re.DOTALL,
)
DURATION_RE = re.compile(r"P(?:\d+D)?(?:T(?:(?P<hours>\d+)H)?(?:(?P<minutes>\d+)M)?)?", re.IGNORECASE)
SERVINGS_RE = re.compile(r"(\d+(?:\.\d+)?)")
SCHEMA_RECIPE_TYPE = "recipe"
JUNK_INGREDIENT_RE = re.compile(r"^(ingredients?|instructions?|directions?|method|for the .+)$", re.IGNORECASE)
HEADING_RE = re.compile(r"<h[1-6][^>]*>\s*(instructions?|directions?|method|preparation)\s*</h[1-6]>", re.IGNORECASE)
TEXT_HEADING_RE = re.compile(r"^(ingredients?|instructions?|directions?|method|preparation|notes?|memories?|tags?|keywords?|cuisine|yield|servings?|prep(?:\s+time)?|cook(?:\s+time)?)[:\s]*$", re.IGNORECASE)
METADATA_LINE_RE = re.compile(r"^(yield|servings?|prep(?:\s+time)?|cook(?:\s+time)?|cuisine|tags?|keywords?)\s*:\s*(.+)$", re.IGNORECASE)
STEP_PREFIX_RE = re.compile(r"^(?:step\s*)?(?P<index>\d+)[\).\:-]\s*(?P<text>.+)$", re.IGNORECASE)
SUBSTEP_PREFIX_RE = re.compile(r"^(?P<index>[a-z])[\).\:-]\s*(?P<text>.+)$", re.IGNORECASE)
LEADING_BULLET_RE = re.compile(r"^[\-\*\u2022\u25E6\u2043]+\s*")
PAGE_MARKER_RE = re.compile(r"^(?:page\s+)?\d+\s*(?:of|/)\s*\d+$", re.IGNORECASE)
QUANTITY_RE = re.compile(
    r"^(?P<quantity>(?:\d+\s+\d+/\d+)|(?:\d+-\d+/\d+)|(?:\d+/\d+)|(?:\d+(?:\.\d+)?))\b"
)
PACKAGE_NOTE_RE = re.compile(r"^\((?P<note>[^)]*?\d[^)]*)\)\s*")
STEP_VERB_RE = re.compile(
    r"^(add|arrange|bake|beat|blend|boil|bring|broil|chill|combine|cook|cover|cut|drain|fold|garnish|grill|heat|knead|let|marinate|mix|place|pour|preheat|reduce|refrigerate|rest|roast|saute|sauté|season|serve|simmer|sprinkle|stir|toast|top|transfer|whisk)\b",
    re.IGNORECASE,
)

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


def clean_text(value: Any) -> str:
    if value is None:
        return ""
    text = unescape(str(value))
    text = re.sub(r"<[^>]+>", " ", text)
    text = text.replace("\xa0", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def normalize_keywords(value: Any) -> list[str]:
    if isinstance(value, str):
        parts = [part.strip() for part in value.split(",")]
    elif isinstance(value, list):
        parts = [clean_text(part) for part in value]
    else:
        parts = []

    unique_parts: list[str] = []
    seen: set[str] = set()
    for part in parts:
        normalized = part.lower()
        if not part or normalized in seen:
            continue
        seen.add(normalized)
        unique_parts.append(part)
    return unique_parts


def parse_duration_minutes(value: Any) -> int | None:
    if not value:
        return None
    text = clean_text(value)
    match = DURATION_RE.fullmatch(text)
    if not match:
        return None
    hours = int(match.group("hours") or 0)
    minutes = int(match.group("minutes") or 0)
    total = hours * 60 + minutes
    return total or None


def parse_servings(value: Any) -> float | None:
    if isinstance(value, list):
        value = next((item for item in value if item), "")
    text = clean_text(value)
    if not text:
        return None
    match = SERVINGS_RE.search(text)
    if not match:
        return None
    try:
        return float(match.group(1))
    except ValueError:
        return None


def recipe_nodes_from_json_ld(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        nodes: list[dict[str, Any]] = []
        for item in payload:
            nodes.extend(recipe_nodes_from_json_ld(item))
        return nodes

    if not isinstance(payload, dict):
        return []

    nodes = []
    graph = payload.get("@graph")
    if isinstance(graph, list):
        nodes.extend(recipe_nodes_from_json_ld(graph))

    raw_type = payload.get("@type")
    types = raw_type if isinstance(raw_type, list) else [raw_type]
    normalized_types = {clean_text(item).lower() for item in types if item}
    if SCHEMA_RECIPE_TYPE in normalized_types:
        nodes.append(payload)

    return nodes


def first_non_empty(*values: Any) -> str:
    for value in values:
        if isinstance(value, (list, tuple)):
            nested = first_non_empty(*value)
            if nested:
                return nested
        text = clean_text(value)
        if text:
            return text
    return ""


def _normalized_substeps(steps: list[RecipeStepPayload]) -> list[RecipeStepPayload]:
    normalized: list[RecipeStepPayload] = []
    for index, step in enumerate(steps, start=1):
        instruction = clean_text(step.instruction)
        if not instruction:
            continue
        normalized.append(
            RecipeStepPayload(
                step_id=step.step_id,
                sort_order=index,
                instruction=instruction,
                substeps=[],
            )
        )
    return normalized


def extract_instruction_steps(value: Any) -> list[RecipeStepPayload]:
    if isinstance(value, str):
        text = clean_text(value)
        return [RecipeStepPayload(sort_order=1, instruction=text)] if text else []

    if isinstance(value, list):
        steps: list[RecipeStepPayload] = []
        for item in value:
            steps.extend(extract_instruction_steps(item))
        return [
            RecipeStepPayload(
                step_id=step.step_id,
                sort_order=index,
                instruction=step.instruction,
                substeps=_normalized_substeps(step.substeps),
            )
            for index, step in enumerate(steps, start=1)
            if step.instruction.strip()
        ]

    if isinstance(value, dict):
        if "itemListElement" in value:
            nested_steps = extract_instruction_steps(value.get("itemListElement"))
            title = first_non_empty(value.get("text"), value.get("name"))
            if title and nested_steps:
                return [
                    RecipeStepPayload(
                        sort_order=1,
                        instruction=title,
                        substeps=_normalized_substeps(nested_steps),
                    )
                ]
            return nested_steps
        text = first_non_empty(value.get("text"), value.get("name"))
        return [RecipeStepPayload(sort_order=1, instruction=text)] if text else []

    return []


def extract_ingredient_lines(value: Any) -> list[str]:
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


def source_label_from_node(node: dict[str, Any], hostname: str) -> str:
    publisher = node.get("publisher")
    author = node.get("author")
    return first_non_empty(
        publisher.get("name") if isinstance(publisher, dict) else None,
        author.get("name") if isinstance(author, dict) else None,
        hostname,
    )


class InstructionHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.active_heading = False
        self.current_heading = ""
        self.capture_mode = False
        self.list_depth = 0
        self.current_li_chunks: list[str] = []
        self.pending_substeps: list[str] = []
        self.steps: list[RecipeStepPayload] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        normalized_tag = tag.lower()
        if normalized_tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            self.active_heading = True
            self.current_heading = ""
            return
        if not self.capture_mode:
            return
        if normalized_tag in {"ol", "ul"}:
            self.list_depth += 1
        elif normalized_tag == "li":
            self.current_li_chunks = []

    def handle_endtag(self, tag: str) -> None:
        normalized_tag = tag.lower()
        if normalized_tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            heading = clean_text(self.current_heading)
            self.capture_mode = bool(re.fullmatch(r"instructions?|directions?|method|preparation", heading, re.IGNORECASE))
            self.active_heading = False
            self.current_heading = ""
            return
        if not self.capture_mode:
            return
        if normalized_tag == "li":
            text = clean_text(" ".join(self.current_li_chunks))
            if text:
                if self.list_depth <= 1:
                    self.steps.append(
                        RecipeStepPayload(
                            sort_order=len(self.steps) + 1,
                            instruction=text,
                            substeps=[RecipeStepPayload(sort_order=index, instruction=value) for index, value in enumerate(self.pending_substeps, start=1)],
                        )
                    )
                    self.pending_substeps = []
                else:
                    self.pending_substeps.append(text)
            self.current_li_chunks = []
        elif normalized_tag in {"ol", "ul"}:
            self.list_depth = max(self.list_depth - 1, 0)
        elif normalized_tag in {"section", "article"} and self.steps:
            self.capture_mode = False

    def handle_data(self, data: str) -> None:
        if self.active_heading:
            self.current_heading += data
        elif self.capture_mode and self.list_depth > 0:
            self.current_li_chunks.append(data)


def extract_instruction_steps_from_html(html: str) -> list[RecipeStepPayload]:
    if not HEADING_RE.search(html):
        return []
    parser = InstructionHTMLParser()
    parser.feed(html)
    return parser.steps


def parse_recipe_html(html: str, url: str) -> RecipePayload:
    blocks = SCRIPT_RE.findall(html)
    recipe_nodes: list[dict[str, Any]] = []
    for block in blocks:
        try:
            parsed = json.loads(unescape(block))
        except json.JSONDecodeError:
            continue
        recipe_nodes.extend(recipe_nodes_from_json_ld(parsed))

    if not recipe_nodes:
        raise ValueError("No structured recipe data found on that page.")

    node = recipe_nodes[0]
    parsed_url = urllib_parse.urlparse(url)
    hostname = parsed_url.netloc.lower().removeprefix("www.")
    ingredient_lines = extract_ingredient_lines(node.get("recipeIngredient"))
    instruction_steps = extract_instruction_steps(node.get("recipeInstructions"))
    if not instruction_steps:
        instruction_steps = extract_instruction_steps_from_html(html)

    if not ingredient_lines and not instruction_steps:
        raise ValueError("Recipe data was found, but the ingredients and steps were empty.")

    instruction_lines: list[str] = []
    for index, step in enumerate(instruction_steps, start=1):
        instruction_lines.append(f"{index}. {step.instruction}")
        for sub_index, substep in enumerate(step.substeps, start=1):
            instruction_lines.append(f"   {chr(ord('a') + sub_index - 1)}. {substep.instruction}")
    instructions_summary = "\n".join(instruction_lines)

    return RecipePayload(
        name=first_non_empty(node.get("name"), parsed_url.path.strip("/").replace("-", " ").title(), "Imported recipe"),
        meal_type="",
        cuisine=first_non_empty(node.get("recipeCuisine")),
        servings=parse_servings(node.get("recipeYield")),
        prep_minutes=parse_duration_minutes(node.get("prepTime")),
        cook_minutes=parse_duration_minutes(node.get("cookTime")),
        tags=normalize_keywords(node.get("keywords")),
        instructions_summary=instructions_summary,
        favorite=False,
        source="url_import",
        source_label=source_label_from_node(node, hostname),
        source_url=url,
        notes="",
        ingredients=ingredient_payloads_from_lines(ingredient_lines),
        steps=instruction_steps,
    )


def clean_text_line(value: Any) -> str:
    text = clean_text(value)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def looks_like_title(line: str) -> bool:
    normalized = line.strip()
    if not normalized or len(normalized) > 120:
        return False
    if TEXT_HEADING_RE.fullmatch(normalized):
        return False
    if METADATA_LINE_RE.match(normalized):
        return False
    return any(character.isalpha() for character in normalized)


def strip_leading_bullet(line: str) -> str:
    return LEADING_BULLET_RE.sub("", line).strip()


def parse_duration_line(value: str) -> int | None:
    match = SERVINGS_RE.search(value)
    if not match:
        return None
    try:
        return int(float(match.group(1)))
    except ValueError:
        return None


def parse_metadata_line(
    line: str,
    *,
    tags: list[str],
) -> tuple[str | None, Any | None]:
    match = METADATA_LINE_RE.match(line)
    if not match:
        return None, None

    field = clean_text(match.group(1)).lower()
    value = clean_text(match.group(2))
    if not value:
        return None, None
    if field in {"yield", "servings", "serving"}:
        return "servings", parse_servings(value)
    if field in {"prep", "prep time"}:
        return "prep_minutes", parse_duration_line(value)
    if field in {"cook", "cook time"}:
        return "cook_minutes", parse_duration_line(value)
    if field == "cuisine":
        return "cuisine", value
    if field in {"tag", "tags", "keyword", "keywords"}:
        tags.extend(normalize_keywords(value))
        return "tags", tags
    return None, None


def normalize_import_lines(text: str) -> list[str]:
    normalized_text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines: list[str] = []

    for raw_line in normalized_text.split("\n"):
        line = clean_text_line(raw_line)
        if not line or PAGE_MARKER_RE.fullmatch(line):
            continue
        if lines and _should_join_wrapped_line(lines[-1], line):
            lines[-1] = _join_wrapped_lines(lines[-1], line)
            continue
        if lines and lines[-1].lower() == line.lower():
            continue
        lines.append(line)

    return lines


def _should_join_wrapped_line(previous_line: str, next_line: str) -> bool:
    if not previous_line or not next_line:
        return False
    if TEXT_HEADING_RE.fullmatch(previous_line) or TEXT_HEADING_RE.fullmatch(next_line):
        return False
    if STEP_PREFIX_RE.match(next_line) or SUBSTEP_PREFIX_RE.match(next_line):
        return False
    if previous_line.endswith("-"):
        return True
    if previous_line.endswith(",") and next_line[:1].islower():
        return True
    if previous_line.endswith("("):
        return True
    if previous_line.endswith(")") and _has_quantity_prefix(previous_line) and len(previous_line.split()) <= 3:
        return True
    return False


def _join_wrapped_lines(previous_line: str, next_line: str) -> str:
    if previous_line.endswith("-"):
        previous_line = previous_line[:-1].rstrip()
    elif previous_line.endswith(","):
        previous_line = previous_line.rstrip()
    else:
        previous_line = previous_line.rstrip()
    return clean_text_line(f"{previous_line} {next_line}")


def looks_like_step_line(line: str) -> bool:
    cleaned = strip_leading_bullet(clean_text_line(line))
    if not cleaned:
        return False
    if STEP_PREFIX_RE.match(cleaned) or SUBSTEP_PREFIX_RE.match(cleaned):
        return True
    if cleaned.endswith(".") and len(cleaned.split()) >= 4:
        return True
    return bool(STEP_VERB_RE.match(cleaned) and len(cleaned.split()) >= 4)


def _has_quantity_prefix(line: str) -> bool:
    return QUANTITY_RE.match(normalize_fraction_text(clean_text_line(line))) is not None


def looks_like_ingredient_line(line: str) -> bool:
    cleaned = strip_leading_bullet(clean_text_line(line))
    if not cleaned or TEXT_HEADING_RE.fullmatch(cleaned) or METADATA_LINE_RE.match(cleaned):
        return False
    lowered = cleaned.lower()
    if _has_quantity_prefix(cleaned):
        return True
    if any(phrase in lowered for phrase in NOTE_PHRASES) and len(cleaned.split()) <= 6:
        return True
    if cleaned.endswith(".") or STEP_VERB_RE.match(cleaned):
        return False
    return len(cleaned.split()) <= 8


def infer_sections_from_body_lines(lines: list[str]) -> tuple[list[str], list[str], list[str]]:
    body_lines = [clean_text_line(line) for line in lines if clean_text_line(line)]
    if not body_lines:
        return [], [], []

    step_start_index = next((index for index, line in enumerate(body_lines) if looks_like_step_line(line)), None)

    if step_start_index is not None:
        ingredient_candidates = body_lines[:step_start_index]
        step_candidates = body_lines[step_start_index:]
        ingredients = [line for line in ingredient_candidates if looks_like_ingredient_line(line)]
        notes = [line for line in ingredient_candidates if line not in ingredients]
        return ingredients, step_candidates, notes

    ingredients = [line for line in body_lines if looks_like_ingredient_line(line)]
    notes = [line for line in body_lines if line not in ingredients]
    return ingredients, [], notes


def parse_text_steps(lines: list[str]) -> list[RecipeStepPayload]:
    steps: list[RecipeStepPayload] = []
    current_instruction = ""
    current_substeps: list[str] = []

    def flush_step() -> None:
        nonlocal current_instruction, current_substeps
        instruction = clean_text_line(current_instruction)
        if not instruction:
            current_instruction = ""
            current_substeps = []
            return
        steps.append(
            RecipeStepPayload(
                sort_order=len(steps) + 1,
                instruction=instruction,
                substeps=[
                    RecipeStepPayload(sort_order=index, instruction=clean_text_line(substep))
                    for index, substep in enumerate(current_substeps, start=1)
                    if clean_text_line(substep)
                ],
            )
        )
        current_instruction = ""
        current_substeps = []

    for raw_line in lines:
        line = strip_leading_bullet(clean_text_line(raw_line))
        if not line or TEXT_HEADING_RE.fullmatch(line):
            continue

        if match := STEP_PREFIX_RE.match(line):
            flush_step()
            current_instruction = match.group("text")
            continue

        if match := SUBSTEP_PREFIX_RE.match(line):
            substep_text = clean_text_line(match.group("text"))
            if substep_text:
                current_substeps.append(substep_text)
            continue

        if current_instruction:
            current_instruction = f"{current_instruction} {line}".strip()
        else:
            current_instruction = line

    flush_step()
    return steps


def import_recipe_from_text(
    text: str,
    *,
    title: str = "",
    source: str = "scan_import",
    source_label: str = "",
    source_url: str = "",
) -> RecipePayload:
    lines = normalize_import_lines(text)
    if not lines:
        raise ValueError("No readable recipe text was found.")

    recipe_title = clean_text(title)
    cuisine = ""
    servings = None
    prep_minutes = None
    cook_minutes = None
    tags: list[str] = []
    notes_lines: list[str] = []
    ingredient_lines: list[str] = []
    instruction_lines: list[str] = []
    body_lines: list[str] = []
    current_section = "body"

    for line in lines:
        normalized = line.rstrip(":").strip()
        lower_line = normalized.lower()

        metadata_field, metadata_value = parse_metadata_line(normalized, tags=tags)
        if metadata_field == "servings":
            servings = metadata_value
            continue
        if metadata_field == "prep_minutes":
            prep_minutes = metadata_value
            continue
        if metadata_field == "cook_minutes":
            cook_minutes = metadata_value
            continue
        if metadata_field == "cuisine":
            cuisine = metadata_value or cuisine
            continue
        if metadata_field == "tags":
            continue

        if lower_line in {"ingredients", "ingredient"}:
            current_section = "ingredients"
            continue
        if lower_line in {"instructions", "instruction", "directions", "direction", "method", "preparation"}:
            current_section = "steps"
            continue
        if lower_line in {"notes", "note", "memories", "memory"}:
            current_section = "notes"
            continue

        if not recipe_title and current_section == "body" and looks_like_title(normalized):
            recipe_title = normalized
            continue

        if current_section == "ingredients":
            ingredient_lines.append(normalized)
            continue
        if current_section == "steps":
            instruction_lines.append(normalized)
            continue
        if current_section == "notes":
            notes_lines.append(normalized)
            continue
        if current_section == "body":
            body_lines.append(normalized)

    if not recipe_title:
        recipe_title = "Imported recipe"

    inferred_ingredients, inferred_steps, inferred_notes = infer_sections_from_body_lines(body_lines)
    if not ingredient_lines:
        ingredient_lines = inferred_ingredients
    if not instruction_lines:
        instruction_lines = inferred_steps
    if not notes_lines:
        notes_lines = inferred_notes

    cleaned_ingredients = extract_ingredient_lines([strip_leading_bullet(line) for line in ingredient_lines])
    cleaned_steps = parse_text_steps(instruction_lines)

    if not cleaned_ingredients and not cleaned_steps:
        raise ValueError("Recipe text was found, but ingredients and instructions could not be identified.")

    instruction_lines_summary: list[str] = []
    for index, step in enumerate(cleaned_steps, start=1):
        instruction_lines_summary.append(f"{index}. {step.instruction}")
        for sub_index, substep in enumerate(step.substeps, start=1):
            instruction_lines_summary.append(f"   {chr(ord('a') + sub_index - 1)}. {substep.instruction}")

    return RecipePayload(
        name=recipe_title,
        meal_type="",
        cuisine=cuisine,
        servings=servings,
        prep_minutes=prep_minutes,
        cook_minutes=cook_minutes,
        tags=tags,
        instructions_summary="\n".join(instruction_lines_summary),
        favorite=False,
        source=source,
        source_label=source_label,
        source_url=source_url,
        notes="\n".join(notes_lines).strip(),
        ingredients=ingredient_payloads_from_lines(cleaned_ingredients),
        steps=cleaned_steps,
    )


def import_recipe_from_url(url: str) -> RecipePayload:
    normalized_url = clean_text(url)
    if not normalized_url.startswith(("http://", "https://")):
        raise ValueError("Recipe URL must start with http:// or https://")

    request = urllib_request.Request(
        normalized_url,
        headers={
            "User-Agent": "SimmerSmith/1.0 (+https://simmersmith.app)",
            "Accept": "text/html,application/xhtml+xml",
        },
    )
    with urllib_request.urlopen(request, timeout=20.0) as response:
        content_type = response.headers.get("Content-Type", "")
        if "html" not in content_type:
            raise ValueError("That URL did not return an HTML page.")
        html = response.read().decode("utf-8", errors="replace")

    return parse_recipe_html(html, normalized_url)
