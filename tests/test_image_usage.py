"""Tests for image generation cost telemetry (M17.1)."""
from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy.orm import Session
from unittest.mock import patch

from app.models import ImageGenUsage, Recipe, User, RecipeImage
from app.models._base import new_id, utcnow
from app.services.image_usage import (
    record_image_gen,
    usage_summary,
    global_usage_summary,
)
from app.services.recipe_image_ai import RecipeImageError


@pytest.fixture
def user1(db_session: Session) -> User:
    """Create a test user."""
    user = User(id=new_id(), email="user1@example.com")
    db_session.add(user)
    db_session.commit()
    return user


@pytest.fixture
def user2(db_session: Session) -> User:
    """Create another test user."""
    user = User(id=new_id(), email="user2@example.com")
    db_session.add(user)
    db_session.commit()
    return user


@pytest.fixture
def recipe1(db_session: Session, user1: User) -> Recipe:
    """Create a test recipe."""
    recipe = Recipe(
        id=new_id(),
        user_id=user1.id,
        name="Test Recipe",
        cuisine="italian",
        meal_type="dinner",
        servings=4,
        prep_minutes=10,
        cook_minutes=20,
        ingredients=[],
        steps=[],
    )
    db_session.add(recipe)
    db_session.commit()
    return recipe


def test_record_image_gen_writes_row(db_session: Session, user1: User, recipe1: Recipe) -> None:
    """record_image_gen writes a row with the correct fields."""
    record_image_gen(
        db_session,
        user_id=user1.id,
        recipe_id=recipe1.id,
        provider="openai",
        model="gpt-image-1",
        trigger="save",
    )
    db_session.commit()

    row = db_session.query(ImageGenUsage).filter_by(user_id=user1.id).first()
    assert row is not None
    assert row.user_id == user1.id
    assert row.recipe_id == recipe1.id
    assert row.provider == "openai"
    assert row.model == "gpt-image-1"
    assert row.est_cost_cents == 4
    assert row.trigger == "save"
    assert row.created_at is not None


def test_record_image_gen_gemini(db_session: Session, user1: User, recipe1: Recipe) -> None:
    """record_image_gen correctly costs Gemini images."""
    record_image_gen(
        db_session,
        user_id=user1.id,
        recipe_id=recipe1.id,
        provider="gemini",
        model="gemini-2.5-flash-image-preview",
        trigger="backfill",
    )
    db_session.commit()

    row = db_session.query(ImageGenUsage).filter_by(user_id=user1.id).first()
    assert row.provider == "gemini"
    assert row.est_cost_cents == 4


def test_record_image_gen_unknown_provider(db_session: Session, user1: User, recipe1: Recipe) -> None:
    """record_image_gen costs unknown providers at 0 cents (graceful degradation)."""
    record_image_gen(
        db_session,
        user_id=user1.id,
        recipe_id=recipe1.id,
        provider="anthropic",
        model="unknown",
        trigger="save",
    )
    db_session.commit()

    row = db_session.query(ImageGenUsage).filter_by(user_id=user1.id).first()
    assert row.est_cost_cents == 0


def test_record_image_gen_nullable_recipe_id(db_session: Session, user1: User) -> None:
    """record_image_gen allows recipe_id=None for deleted recipes."""
    record_image_gen(
        db_session,
        user_id=user1.id,
        recipe_id=None,
        provider="openai",
        model="gpt-image-1",
        trigger="save",
    )
    db_session.commit()

    row = db_session.query(ImageGenUsage).filter_by(user_id=user1.id).first()
    assert row.recipe_id is None


def test_usage_summary_empty_user(db_session: Session, user1: User) -> None:
    """usage_summary returns zero counts for a user with no rows."""
    result = usage_summary(db_session, user1.id, days=30)

    assert result["window_days"] == 30
    assert result["total_count"] == 0
    assert result["total_cost_cents"] == 0
    assert result["by_provider"] == []


def test_usage_summary_single_provider(db_session: Session, user1: User, recipe1: Recipe) -> None:
    """usage_summary returns correct counts for a single provider."""
    for i in range(3):
        record_image_gen(
            db_session,
            user_id=user1.id,
            recipe_id=recipe1.id,
            provider="openai",
            model="gpt-image-1",
            trigger="save",
        )
    db_session.commit()

    result = usage_summary(db_session, user1.id, days=30)

    assert result["total_count"] == 3
    assert result["total_cost_cents"] == 12
    assert len(result["by_provider"]) == 1
    assert result["by_provider"][0]["provider"] == "openai"
    assert result["by_provider"][0]["count"] == 3
    assert result["by_provider"][0]["cost_cents"] == 12


def test_usage_summary_multiple_providers(db_session: Session, user1: User, recipe1: Recipe) -> None:
    """usage_summary aggregates by provider and sorts by count descending."""
    for i in range(2):
        record_image_gen(
            db_session,
            user_id=user1.id,
            recipe_id=recipe1.id,
            provider="gemini",
            model="gemini-2.5-flash-image-preview",
            trigger="save",
        )
    for i in range(3):
        record_image_gen(
            db_session,
            user_id=user1.id,
            recipe_id=recipe1.id,
            provider="openai",
            model="gpt-image-1",
            trigger="backfill",
        )
    db_session.commit()

    result = usage_summary(db_session, user1.id, days=30)

    assert result["total_count"] == 5
    assert result["total_cost_cents"] == 20
    assert len(result["by_provider"]) == 2
    assert result["by_provider"][0]["provider"] == "openai"
    assert result["by_provider"][0]["count"] == 3
    assert result["by_provider"][1]["provider"] == "gemini"
    assert result["by_provider"][1]["count"] == 2


def test_usage_summary_respects_window(db_session: Session, user1: User, recipe1: Recipe) -> None:
    """usage_summary only includes rows within the specified window."""
    record_image_gen(
        db_session,
        user_id=user1.id,
        recipe_id=recipe1.id,
        provider="openai",
        model="gpt-image-1",
        trigger="save",
    )
    db_session.commit()

    old_row = ImageGenUsage(
        id=new_id(),
        user_id=user1.id,
        recipe_id=recipe1.id,
        provider="gemini",
        model="gemini-2.5-flash-image-preview",
        est_cost_cents=4,
        trigger="save",
        created_at=utcnow() - timedelta(days=40),
    )
    db_session.add(old_row)
    db_session.commit()

    result = usage_summary(db_session, user1.id, days=30)
    assert result["total_count"] == 1
    assert result["by_provider"][0]["provider"] == "openai"

    result = usage_summary(db_session, user1.id, days=35)
    assert result["total_count"] == 1

    result = usage_summary(db_session, user1.id, days=50)
    assert result["total_count"] == 2


def test_usage_summary_ignores_other_users(db_session: Session, user1: User, user2: User, recipe1: Recipe) -> None:
    """usage_summary only includes rows for the queried user."""
    record_image_gen(
        db_session,
        user_id=user1.id,
        recipe_id=recipe1.id,
        provider="openai",
        model="gpt-image-1",
        trigger="save",
    )
    record_image_gen(
        db_session,
        user_id=user2.id,
        recipe_id=recipe1.id,
        provider="gemini",
        model="gemini-2.5-flash-image-preview",
        trigger="save",
    )
    db_session.commit()

    result1 = usage_summary(db_session, user1.id, days=30)
    assert result1["total_count"] == 1
    assert result1["by_provider"][0]["provider"] == "openai"

    result2 = usage_summary(db_session, user2.id, days=30)
    assert result2["total_count"] == 1
    assert result2["by_provider"][0]["provider"] == "gemini"


def test_global_usage_summary_empty(db_session: Session) -> None:
    """global_usage_summary returns zero counts when no rows exist."""
    result = global_usage_summary(db_session, days=30)

    assert result["window_days"] == 30
    assert result["total_count"] == 0
    assert result["total_cost_cents"] == 0
    assert result["by_provider"] == []
    assert result["top_users"] == []


def test_global_usage_summary_aggregates(db_session: Session, user1: User, user2: User, recipe1: Recipe) -> None:
    """global_usage_summary returns correct global aggregates."""
    for i in range(3):
        record_image_gen(
            db_session,
            user_id=user1.id,
            recipe_id=recipe1.id,
            provider="openai",
            model="gpt-image-1",
            trigger="save",
        )
    for i in range(2):
        record_image_gen(
            db_session,
            user_id=user2.id,
            recipe_id=recipe1.id,
            provider="gemini",
            model="gemini-2.5-flash-image-preview",
            trigger="save",
        )
    db_session.commit()

    result = global_usage_summary(db_session, days=30)

    assert result["total_count"] == 5
    assert result["total_cost_cents"] == 20
    assert len(result["by_provider"]) == 2
    assert result["by_provider"][0]["provider"] == "openai"
    assert result["by_provider"][0]["count"] == 3
    assert result["by_provider"][1]["provider"] == "gemini"
    assert result["by_provider"][1]["count"] == 2


def test_global_usage_summary_top_users(db_session: Session, user1: User, user2: User, recipe1: Recipe) -> None:
    """global_usage_summary returns top users by count."""
    for i in range(5):
        record_image_gen(
            db_session,
            user_id=user1.id,
            recipe_id=recipe1.id,
            provider="openai",
            model="gpt-image-1",
            trigger="save",
        )
    for i in range(2):
        record_image_gen(
            db_session,
            user_id=user2.id,
            recipe_id=recipe1.id,
            provider="gemini",
            model="gemini-2.5-flash-image-preview",
            trigger="save",
        )
    db_session.commit()

    result = global_usage_summary(db_session, days=30, top_users=10)

    assert len(result["top_users"]) == 2
    assert result["top_users"][0]["user_id"] == user1.id
    assert result["top_users"][0]["count"] == 5
    assert result["top_users"][0]["cost_cents"] == 20
    assert result["top_users"][1]["user_id"] == user2.id
    assert result["top_users"][1]["count"] == 2
    assert result["top_users"][1]["cost_cents"] == 8


def test_global_usage_summary_top_users_limit(db_session: Session, recipe1: Recipe) -> None:
    """global_usage_summary respects the top_users limit."""
    for i in range(15):
        user = User(id=new_id(), email=f"user{i}@example.com")
        db_session.add(user)
        db_session.flush()
        record_image_gen(
            db_session,
            user_id=user.id,
            recipe_id=recipe1.id,
            provider="openai",
            model="gpt-image-1",
            trigger="save",
        )
    db_session.commit()

    result = global_usage_summary(db_session, days=30, top_users=10)

    assert len(result["top_users"]) == 10


def test_save_recipe_logs_usage(client) -> None:
    """POST /api/recipes logs usage on success."""
    from app.config import Settings
    settings = Settings()
    test_user_id = settings.local_user_id

    with patch("app.api.recipes.generate_recipe_image") as mock_gen, \
         patch("app.api.recipes.is_image_gen_configured", return_value=True):
        mock_gen.return_value = (
            b"fake_image_bytes",
            "image/png",
            "a test prompt",
            "openai",
            "gpt-image-1",
        )
        response = client.post(
            "/api/recipes",
            json={
                "name": "Test Recipe",
                "cuisine": "italian",
                "meal_type": "dinner",
                "servings": 4,
                "prep_minutes": 10,
                "cook_minutes": 20,
                "ingredients": [],
                "steps": [],
            },
        )
    assert response.status_code == 200
    recipe_id = response.json()["recipe_id"]

    from app.db import session_scope
    with session_scope() as fresh_session:
        rows = fresh_session.query(ImageGenUsage).filter_by(user_id=test_user_id).all()
        assert len(rows) == 1
        assert rows[0].provider == "openai"
        assert rows[0].model == "gpt-image-1"
        assert rows[0].trigger == "save"
        assert rows[0].recipe_id == recipe_id


def test_save_recipe_skips_usage_on_error(client) -> None:
    """POST /api/recipes does not log usage on generation failure."""
    from app.config import Settings
    settings = Settings()
    test_user_id = settings.local_user_id

    with patch("app.api.recipes.generate_recipe_image") as mock_gen, \
         patch("app.api.recipes.is_image_gen_configured", return_value=True):
        mock_gen.side_effect = RecipeImageError("API key not configured")
        response = client.post(
            "/api/recipes",
            json={
                "name": "Test Recipe",
                "cuisine": "italian",
                "meal_type": "dinner",
                "servings": 4,
                "prep_minutes": 10,
                "cook_minutes": 20,
                "ingredients": [],
                "steps": [],
            },
        )
    assert response.status_code == 200

    from app.db import session_scope
    with session_scope() as fresh_session:
        rows = fresh_session.query(ImageGenUsage).filter_by(user_id=test_user_id).all()
        assert len(rows) == 0


def test_regenerate_logs_usage(client, db_session: Session) -> None:
    """POST /api/recipes/{recipe_id}/image/regenerate logs usage."""
    # Use the default test user (matching the test client's authenticated user)
    from app.config import Settings
    settings = Settings()
    test_user_id = settings.local_user_id

    recipe = Recipe(
        id=new_id(),
        user_id=test_user_id,
        name="Test Recipe",
        cuisine="italian",
        meal_type="dinner",
        servings=4,
        prep_minutes=10,
        cook_minutes=20,
        ingredients=[],
        steps=[],
    )
    db_session.add(recipe)
    image = RecipeImage(
        recipe_id=recipe.id,
        image_bytes=b"old_image",
        mime_type="image/png",
        prompt="old prompt",
    )
    db_session.add(image)
    db_session.commit()

    with patch("app.api.recipe_images.generate_recipe_image") as mock_gen, \
         patch("app.api.recipe_images.is_image_gen_configured", return_value=True):
        mock_gen.return_value = (
            b"new_image_bytes",
            "image/png",
            "new prompt",
            "gemini",
            "gemini-2.5-flash-image-preview",
        )
        response = client.post(f"/api/recipes/{recipe.id}/image/regenerate")
    assert response.status_code == 200

    from app.db import session_scope
    with session_scope() as fresh_session:
        rows = fresh_session.query(ImageGenUsage).filter_by(user_id=test_user_id).all()
        assert len(rows) == 1
        assert rows[0].provider == "gemini"
        assert rows[0].trigger == "regenerate"


def test_admin_route_requires_bearer(client, settings_with_api_token) -> None:
    """GET /api/admin/image-usage requires bearer token."""
    response = client.get("/api/admin/image-usage")
    assert response.status_code == 403


def test_admin_route_rejects_invalid_token(client, settings_with_api_token) -> None:
    """GET /api/admin/image-usage rejects invalid bearer token."""
    response = client.get(
        "/api/admin/image-usage",
        headers={"Authorization": "Bearer invalid_token"},
    )
    assert response.status_code == 403


def test_admin_route_accepts_valid_token(client, db_session: Session, settings_with_api_token) -> None:
    """GET /api/admin/image-usage accepts valid bearer token."""
    response = client.get(
        "/api/admin/image-usage",
        headers={"Authorization": f"Bearer {settings_with_api_token.api_token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert "total_count" in data
    assert "by_provider" in data
    assert "top_users" in data


def test_admin_route_returns_global_data(client, db_session: Session, current_user, settings_with_api_token) -> None:
    """GET /api/admin/image-usage returns global aggregates."""
    recipe = Recipe(
        id=new_id(),
        user_id=current_user.id,
        name="Test Recipe",
        cuisine="italian",
        meal_type="dinner",
        servings=4,
        prep_minutes=10,
        cook_minutes=20,
        ingredients=[],
        steps=[],
    )
    db_session.add(recipe)
    for i in range(3):
        record_image_gen(
            db_session,
            user_id=current_user.id,
            recipe_id=recipe.id,
            provider="openai",
            model="gpt-image-1",
            trigger="save",
        )
    db_session.commit()

    response = client.get(
        "/api/admin/image-usage",
        headers={"Authorization": f"Bearer {settings_with_api_token.api_token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data["total_count"] == 3
    assert data["total_cost_cents"] == 12
    assert len(data["by_provider"]) == 1
    assert data["by_provider"][0]["provider"] == "openai"
