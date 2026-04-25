from __future__ import annotations

from datetime import date, datetime
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models._base import utcnow

if TYPE_CHECKING:
    from app.models.catalog import BaseIngredient, IngredientVariation, RecipeTemplate
    from app.models.week import WeekMeal


class Recipe(Base):
    __tablename__ = "recipes"

    id: Mapped[str] = mapped_column(String(120), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    recipe_template_id: Mapped[str | None] = mapped_column(
        ForeignKey("recipe_templates.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    base_recipe_id: Mapped[str | None] = mapped_column(
        ForeignKey("recipes.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    meal_type: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    cuisine: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    servings: Mapped[float | None] = mapped_column(Float, nullable=True)
    prep_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    cook_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    tags: Mapped[str] = mapped_column(Text, default="", nullable=False)
    instructions_summary: Mapped[str] = mapped_column(Text, default="", nullable=False)
    favorite: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    archived: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    source: Mapped[str] = mapped_column(String(40), default="ai", nullable=False)
    source_label: Mapped[str] = mapped_column(String(255), default="", nullable=False)
    source_url: Mapped[str] = mapped_column(Text, default="", nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    memories: Mapped[str] = mapped_column(Text, default="", nullable=False)
    override_payload_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    last_used: Mapped[date | None] = mapped_column(Date, nullable=True)
    # AI-inferred 1-5 difficulty score; NULL until inferred. Backed by a CHECK
    # constraint in migration 20260425_0021.
    difficulty_score: Mapped[int | None] = mapped_column(Integer, nullable=True)
    kid_friendly: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    base_recipe: Mapped["Recipe | None"] = relationship(
        remote_side=lambda: Recipe.id,
        back_populates="variants",
    )
    recipe_template: Mapped["RecipeTemplate | None"] = relationship(back_populates="recipes")
    variants: Mapped[list["Recipe"]] = relationship(
        back_populates="base_recipe",
        order_by=lambda: Recipe.name,
    )
    ingredients: Mapped[list["RecipeIngredient"]] = relationship(
        back_populates="recipe",
        cascade="all, delete-orphan",
        order_by=lambda: RecipeIngredient.ingredient_name,
    )
    steps: Mapped[list["RecipeStep"]] = relationship(
        back_populates="recipe",
        cascade="all, delete-orphan",
        order_by=lambda: RecipeStep.sort_order,
    )
    meals: Mapped[list["WeekMeal"]] = relationship(back_populates="recipe")


class RecipeIngredient(Base):
    __tablename__ = "recipe_ingredients"

    id: Mapped[str] = mapped_column(String(140), primary_key=True)
    recipe_id: Mapped[str] = mapped_column(ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False)
    base_ingredient_id: Mapped[str | None] = mapped_column(
        ForeignKey("base_ingredients.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    ingredient_variation_id: Mapped[str | None] = mapped_column(
        ForeignKey("ingredient_variations.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    ingredient_name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), index=True, nullable=False)
    quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    unit: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    prep: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    category: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    resolution_status: Mapped[str] = mapped_column(String(24), default="unresolved", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    recipe: Mapped["Recipe"] = relationship(back_populates="ingredients")
    base_ingredient: Mapped["BaseIngredient | None"] = relationship(back_populates="recipe_ingredients")
    ingredient_variation: Mapped["IngredientVariation | None"] = relationship(back_populates="recipe_ingredients")


class RecipeStep(Base):
    __tablename__ = "recipe_steps"

    id: Mapped[str] = mapped_column(String(140), primary_key=True)
    recipe_id: Mapped[str] = mapped_column(ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False)
    parent_step_id: Mapped[str | None] = mapped_column(
        ForeignKey("recipe_steps.id", ondelete="CASCADE"),
        nullable=True,
        index=True,
    )
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    instruction: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    recipe: Mapped["Recipe"] = relationship(back_populates="steps")
