"""Presenter helpers for Event / Guest REST responses. Mirrors the
pattern used in app/services/presenters.py for Week payloads."""
from __future__ import annotations

import json
from typing import Any

from app.models import Event, EventGroceryItem, EventMeal, Guest


def guest_payload(guest: Guest) -> dict[str, Any]:
    return {
        "guest_id": guest.id,
        "name": guest.name,
        "relationship_label": guest.relationship_label,
        "dietary_notes": guest.dietary_notes,
        "allergies": guest.allergies,
        "age_group": guest.age_group,
        "active": guest.active,
        "created_at": guest.created_at,
        "updated_at": guest.updated_at,
    }


def event_meal_ingredient_payload(row: Any) -> dict[str, Any]:
    return {
        "ingredient_id": row.id,
        "ingredient_name": row.ingredient_name,
        "normalized_name": row.normalized_name,
        "base_ingredient_id": row.base_ingredient_id,
        "ingredient_variation_id": row.ingredient_variation_id,
        "quantity": row.quantity,
        "unit": row.unit,
        "prep": row.prep,
        "category": row.category,
        "notes": row.notes,
    }


def event_meal_payload(meal: EventMeal) -> dict[str, Any]:
    try:
        coverage = json.loads(meal.constraint_coverage or "[]")
    except json.JSONDecodeError:
        coverage = []
    return {
        "meal_id": meal.id,
        "role": meal.role,
        "recipe_id": meal.recipe_id,
        "recipe_name": meal.recipe_name,
        "servings": meal.servings,
        "scale_multiplier": meal.scale_multiplier,
        "notes": meal.notes,
        "sort_order": meal.sort_order,
        "ai_generated": meal.ai_generated,
        "approved": meal.approved,
        "assigned_guest_id": meal.assigned_guest_id,
        "constraint_coverage": coverage if isinstance(coverage, list) else [],
        "ingredients": [
            event_meal_ingredient_payload(ing) for ing in meal.inline_ingredients
        ],
        "created_at": meal.created_at,
        "updated_at": meal.updated_at,
    }


def event_grocery_item_payload(item: EventGroceryItem) -> dict[str, Any]:
    try:
        source_meals = json.loads(item.source_meals or "[]")
    except json.JSONDecodeError:
        source_meals = []
    return {
        "grocery_item_id": item.id,
        "ingredient_name": item.ingredient_name,
        "normalized_name": item.normalized_name,
        "base_ingredient_id": item.base_ingredient_id,
        "ingredient_variation_id": item.ingredient_variation_id,
        "total_quantity": item.total_quantity,
        "unit": item.unit,
        "quantity_text": item.quantity_text,
        "category": item.category,
        "source_meals": source_meals if isinstance(source_meals, list) else [],
        "notes": item.notes,
        "review_flag": item.review_flag,
        "merged_into_week_id": item.merged_into_week_id,
        "merged_into_grocery_item_id": item.merged_into_grocery_item_id,
    }


def event_summary_payload(event: Event) -> dict[str, Any]:
    return {
        "event_id": event.id,
        "name": event.name,
        "event_date": event.event_date,
        "occasion": event.occasion,
        "attendee_count": event.attendee_count,
        "status": event.status,
        "linked_week_id": event.linked_week_id,
        "meal_count": len(event.meals),
        "created_at": event.created_at,
        "updated_at": event.updated_at,
    }


def event_payload(event: Event) -> dict[str, Any]:
    return {
        **event_summary_payload(event),
        "notes": event.notes,
        "attendees": [
            {
                "guest_id": row.guest_id,
                "plus_ones": row.plus_ones,
                "guest": guest_payload(row.guest),
            }
            for row in event.attendees
        ],
        "meals": [event_meal_payload(meal) for meal in event.meals],
        "grocery_items": [
            event_grocery_item_payload(item) for item in event.grocery_items
        ],
    }
