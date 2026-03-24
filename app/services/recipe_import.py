from __future__ import annotations

import json
import re
from html import unescape
from html.parser import HTMLParser
from typing import Any
from urllib import parse as urllib_parse
from urllib import request as urllib_request

from app.schemas import RecipeIngredientPayload, RecipePayload, RecipeStepPayload


SCRIPT_RE = re.compile(
    r"<script[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>",
    re.IGNORECASE | re.DOTALL,
)
DURATION_RE = re.compile(r"P(?:\d+D)?(?:T(?:(?P<hours>\d+)H)?(?:(?P<minutes>\d+)M)?)?", re.IGNORECASE)
SERVINGS_RE = re.compile(r"(\d+(?:\.\d+)?)")
SCHEMA_RECIPE_TYPE = "recipe"
JUNK_INGREDIENT_RE = re.compile(r"^(ingredients?|instructions?|directions?|method|for the .+)$", re.IGNORECASE)
HEADING_RE = re.compile(r"<h[1-6][^>]*>\s*(instructions?|directions?|method|preparation)\s*</h[1-6]>", re.IGNORECASE)


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
        ingredients=[RecipeIngredientPayload(ingredient_name=line) for line in ingredient_lines],
        steps=instruction_steps,
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
