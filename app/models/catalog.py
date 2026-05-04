from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models._base import new_id, utcnow

if TYPE_CHECKING:
    from app.models.recipe import Recipe, RecipeIngredient
    from app.models.week import GroceryItem, WeekMealIngredient


class ManagedListItem(Base):
    __tablename__ = "managed_list_items"
    __table_args__ = (UniqueConstraint("kind", "normalized_name", name="uq_managed_list_kind_name"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    kind: Mapped[str] = mapped_column(String(24), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(120), index=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )


class RecipeTemplate(Base):
    __tablename__ = "recipe_templates"

    id: Mapped[str] = mapped_column(String(120), primary_key=True)
    slug: Mapped[str] = mapped_column(String(120), unique=True, index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[str] = mapped_column(Text, default="", nullable=False)
    section_order_json: Mapped[str] = mapped_column(Text, default="[]", nullable=False)
    share_source: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    share_memories: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    built_in: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    recipes: Mapped[list["Recipe"]] = relationship(back_populates="recipe_template")


class NutritionItem(Base):
    __tablename__ = "nutrition_items"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), unique=True, index=True, nullable=False)
    reference_amount: Mapped[float] = mapped_column(Float, default=1.0, nullable=False)
    reference_unit: Mapped[str] = mapped_column(String(40), default="ea", nullable=False)
    calories: Mapped[float] = mapped_column(Float, nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    ingredient_matches: Mapped[list["IngredientNutritionMatch"]] = relationship(
        back_populates="nutrition_item",
        cascade="all, delete-orphan",
    )


class BaseIngredient(Base):
    __tablename__ = "base_ingredients"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), unique=True, index=True, nullable=False)
    category: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    default_unit: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    source_name: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    source_record_id: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    source_url: Mapped[str] = mapped_column(Text, default="", nullable=False)
    source_payload_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    override_payload_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    provisional: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    merged_into_id: Mapped[str | None] = mapped_column(
        ForeignKey("base_ingredients.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    nutrition_reference_amount: Mapped[float | None] = mapped_column(Float, nullable=True)
    nutrition_reference_unit: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    calories: Mapped[float | None] = mapped_column(Float, nullable=True)
    protein_g: Mapped[float | None] = mapped_column(Float, nullable=True)
    carbs_g: Mapped[float | None] = mapped_column(Float, nullable=True)
    fat_g: Mapped[float | None] = mapped_column(Float, nullable=True)
    fiber_g: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    variations: Mapped[list["IngredientVariation"]] = relationship(
        back_populates="base_ingredient",
        cascade="all, delete-orphan",
        order_by=lambda: IngredientVariation.name,
    )
    recipe_ingredients: Mapped[list["RecipeIngredient"]] = relationship(back_populates="base_ingredient")
    week_meal_ingredients: Mapped[list["WeekMealIngredient"]] = relationship(back_populates="base_ingredient")
    grocery_items: Mapped[list["GroceryItem"]] = relationship(back_populates="base_ingredient")
    preferences: Mapped[list["IngredientPreference"]] = relationship(
        back_populates="base_ingredient",
        cascade="all, delete-orphan",
    )
    merged_into: Mapped["BaseIngredient | None"] = relationship(remote_side=lambda: BaseIngredient.id)


class IngredientVariation(Base):
    __tablename__ = "ingredient_variations"
    __table_args__ = (UniqueConstraint("base_ingredient_id", "normalized_name", name="uq_variation_base_name"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    base_ingredient_id: Mapped[str] = mapped_column(
        ForeignKey("base_ingredients.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), index=True, nullable=False)
    brand: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    upc: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    package_size_amount: Mapped[float | None] = mapped_column(Float, nullable=True)
    package_size_unit: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    count_per_package: Mapped[float | None] = mapped_column(Float, nullable=True)
    product_url: Mapped[str] = mapped_column(Text, default="", nullable=False)
    retailer_hint: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    source_name: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    source_record_id: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    source_url: Mapped[str] = mapped_column(Text, default="", nullable=False)
    source_payload_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    override_payload_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    merged_into_id: Mapped[str | None] = mapped_column(
        ForeignKey("ingredient_variations.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    nutrition_reference_amount: Mapped[float | None] = mapped_column(Float, nullable=True)
    nutrition_reference_unit: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    calories: Mapped[float | None] = mapped_column(Float, nullable=True)
    protein_g: Mapped[float | None] = mapped_column(Float, nullable=True)
    carbs_g: Mapped[float | None] = mapped_column(Float, nullable=True)
    fat_g: Mapped[float | None] = mapped_column(Float, nullable=True)
    fiber_g: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    base_ingredient: Mapped["BaseIngredient"] = relationship(back_populates="variations")
    recipe_ingredients: Mapped[list["RecipeIngredient"]] = relationship(back_populates="ingredient_variation")
    week_meal_ingredients: Mapped[list["WeekMealIngredient"]] = relationship(back_populates="ingredient_variation")
    grocery_items: Mapped[list["GroceryItem"]] = relationship(back_populates="ingredient_variation")
    preferences: Mapped[list["IngredientPreference"]] = relationship(back_populates="preferred_variation")
    merged_into: Mapped["IngredientVariation | None"] = relationship(remote_side=lambda: IngredientVariation.id)


class IngredientPreference(Base):
    __tablename__ = "ingredient_preferences"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "base_ingredient_id", "rank",
            name="uq_ingredient_preferences_user_base_rank",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    base_ingredient_id: Mapped[str] = mapped_column(
        ForeignKey("base_ingredients.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    preferred_variation_id: Mapped[str | None] = mapped_column(
        ForeignKey("ingredient_variations.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    preferred_brand: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    choice_mode: Mapped[str] = mapped_column(String(32), default="preferred", nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    # M24: ranked preferences. `rank=1` is the primary pick; `rank=2`
    # is the secondary fallback used by the M23 cart-automation skill
    # when the primary is out of stock. Higher ranks are allowed but
    # the iOS UI surfaces 1-3 today.
    rank: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    base_ingredient: Mapped["BaseIngredient"] = relationship(back_populates="preferences")
    preferred_variation: Mapped["IngredientVariation | None"] = relationship(back_populates="preferences")


class IngredientNutritionMatch(Base):
    __tablename__ = "ingredient_nutrition_matches"
    __table_args__ = (UniqueConstraint("normalized_ingredient_name", name="uq_ingredient_nutrition_match_name"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    ingredient_name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_ingredient_name: Mapped[str] = mapped_column(String(255), index=True, nullable=False)
    nutrition_item_id: Mapped[str] = mapped_column(ForeignKey("nutrition_items.id", ondelete="CASCADE"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    nutrition_item: Mapped["NutritionItem"] = relationship(back_populates="ingredient_matches")
