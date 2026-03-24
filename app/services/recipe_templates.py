from __future__ import annotations

import json

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import RecipeTemplate


DEFAULT_RECIPE_TEMPLATES = (
    {
        "id": "recipe-template-standard",
        "slug": "standard",
        "name": "Standard",
        "description": "Balanced recipe card with ingredients, steps, notes, and source context.",
        "section_order": ["title", "meta", "source", "memories", "ingredients", "steps", "notes", "nutrition"],
        "share_source": True,
        "share_memories": True,
        "built_in": True,
    },
    {
        "id": "recipe-template-weeknight",
        "slug": "weeknight",
        "name": "Weeknight",
        "description": "Compact layout for fast dinner execution.",
        "section_order": ["title", "meta", "ingredients", "steps", "notes", "nutrition"],
        "share_source": False,
        "share_memories": False,
        "built_in": True,
    },
    {
        "id": "recipe-template-story",
        "slug": "story",
        "name": "Story",
        "description": "Keeps provenance and memories visible for family recipes and keepsakes.",
        "section_order": ["title", "source", "memories", "meta", "ingredients", "steps", "notes", "nutrition"],
        "share_source": True,
        "share_memories": True,
        "built_in": True,
    },
)

DEFAULT_TEMPLATE_ID = DEFAULT_RECIPE_TEMPLATES[0]["id"]


def template_payload(template: RecipeTemplate) -> dict[str, object]:
    try:
        section_order = json.loads(template.section_order_json or "[]")
    except json.JSONDecodeError:
        section_order = []
    return {
        "template_id": template.id,
        "slug": template.slug,
        "name": template.name,
        "description": template.description,
        "section_order": section_order if isinstance(section_order, list) else [],
        "share_source": template.share_source,
        "share_memories": template.share_memories,
        "built_in": template.built_in,
        "updated_at": template.updated_at,
    }


def list_templates(session: Session) -> list[RecipeTemplate]:
    ensure_default_templates(session)
    return list(session.scalars(select(RecipeTemplate).order_by(RecipeTemplate.built_in.desc(), RecipeTemplate.name)).all())


def get_template(session: Session, template_id: str) -> RecipeTemplate | None:
    ensure_default_templates(session)
    return session.get(RecipeTemplate, template_id)


def default_template(session: Session) -> RecipeTemplate:
    ensure_default_templates(session)
    template = session.get(RecipeTemplate, DEFAULT_TEMPLATE_ID)
    if template is None:
        raise ValueError("Default recipe template is missing")
    return template


def ensure_default_templates(session: Session) -> None:
    for seed in DEFAULT_RECIPE_TEMPLATES:
        template = session.get(RecipeTemplate, seed["id"])
        if template is None:
            template = RecipeTemplate(id=seed["id"])
            session.add(template)
        template.slug = str(seed["slug"])
        template.name = str(seed["name"])
        template.description = str(seed["description"])
        template.section_order_json = json.dumps(seed["section_order"])
        template.share_source = bool(seed["share_source"])
        template.share_memories = bool(seed["share_memories"])
        template.built_in = bool(seed["built_in"])
    session.flush()
