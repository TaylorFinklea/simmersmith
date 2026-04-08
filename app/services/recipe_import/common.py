from __future__ import annotations

import re
from html import unescape
from typing import Any

DURATION_RE = re.compile(r"P(?:\d+D)?(?:T(?:(?P<hours>\d+)H)?(?:(?P<minutes>\d+)M)?)?", re.IGNORECASE)
SERVINGS_RE = re.compile(r"(\d+(?:\.\d+)?)")


def clean_text(value: Any) -> str:
    if value is None:
        return ""
    text = unescape(str(value))
    text = re.sub(r"<[^>]+>", " ", text)
    text = text.replace("\xa0", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def clean_text_line(value: Any) -> str:
    text = clean_text(value)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


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
