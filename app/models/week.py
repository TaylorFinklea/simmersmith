from __future__ import annotations

from datetime import date, datetime
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models._base import new_id, utcnow
from app.models.ai import AIRun

if TYPE_CHECKING:
    from app.models.catalog import BaseIngredient, IngredientVariation
    from app.models.recipe import Recipe


class Week(Base):
    __tablename__ = "weeks"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    week_start: Mapped[date] = mapped_column(Date, unique=True, index=True, nullable=False)
    week_end: Mapped[date] = mapped_column(Date, nullable=False)
    status: Mapped[str] = mapped_column(String(32), default="staging", nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    ready_for_ai_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    priced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    meals: Mapped[list["WeekMeal"]] = relationship(
        back_populates="week",
        cascade="all, delete-orphan",
        order_by=lambda: (WeekMeal.meal_date, WeekMeal.sort_order),
    )
    grocery_items: Mapped[list["GroceryItem"]] = relationship(
        back_populates="week",
        cascade="all, delete-orphan",
        order_by=lambda: (GroceryItem.category, GroceryItem.ingredient_name),
    )
    ai_runs: Mapped[list["AIRun"]] = relationship(
        back_populates="week",
        cascade="all, delete-orphan",
        order_by=lambda: AIRun.created_at.desc(),
    )
    pricing_runs: Mapped[list["PricingRun"]] = relationship(
        back_populates="week",
        cascade="all, delete-orphan",
        order_by=lambda: PricingRun.requested_at.desc(),
    )
    change_batches: Mapped[list["WeekChangeBatch"]] = relationship(
        back_populates="week",
        cascade="all, delete-orphan",
        order_by=lambda: WeekChangeBatch.created_at.desc(),
    )
    feedback_entries: Mapped[list["FeedbackEntry"]] = relationship(
        back_populates="week",
        cascade="all, delete-orphan",
        order_by=lambda: FeedbackEntry.created_at.desc(),
    )
    export_runs: Mapped[list["ExportRun"]] = relationship(
        back_populates="week",
        cascade="all, delete-orphan",
        order_by=lambda: ExportRun.created_at.desc(),
    )


class WeekMeal(Base):
    __tablename__ = "week_meals"
    __table_args__ = (UniqueConstraint("week_id", "day_name", "slot", name="uq_week_day_slot"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    week_id: Mapped[str] = mapped_column(ForeignKey("weeks.id", ondelete="CASCADE"), nullable=False)
    day_name: Mapped[str] = mapped_column(String(20), nullable=False)
    meal_date: Mapped[date] = mapped_column(Date, nullable=False)
    slot: Mapped[str] = mapped_column(String(20), nullable=False)
    recipe_id: Mapped[str | None] = mapped_column(ForeignKey("recipes.id", ondelete="SET NULL"), nullable=True)
    recipe_name: Mapped[str] = mapped_column(String(255), nullable=False)
    servings: Mapped[float | None] = mapped_column(Float, nullable=True)
    scale_multiplier: Mapped[float] = mapped_column(Float, default=1.0, nullable=False)
    source: Mapped[str] = mapped_column(String(40), default="ai", nullable=False)
    approved: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    ai_generated: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    week: Mapped["Week"] = relationship(back_populates="meals")
    recipe: Mapped["Recipe | None"] = relationship(back_populates="meals")
    inline_ingredients: Mapped[list["WeekMealIngredient"]] = relationship(
        back_populates="week_meal",
        cascade="all, delete-orphan",
        order_by=lambda: WeekMealIngredient.ingredient_name,
    )
    feedback_entries: Mapped[list["FeedbackEntry"]] = relationship(back_populates="meal")


class WeekMealIngredient(Base):
    __tablename__ = "week_meal_ingredients"

    id: Mapped[str] = mapped_column(String(140), primary_key=True)
    week_meal_id: Mapped[str] = mapped_column(ForeignKey("week_meals.id", ondelete="CASCADE"), nullable=False)
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

    week_meal: Mapped["WeekMeal"] = relationship(back_populates="inline_ingredients")
    base_ingredient: Mapped["BaseIngredient | None"] = relationship(back_populates="week_meal_ingredients")
    ingredient_variation: Mapped["IngredientVariation | None"] = relationship(back_populates="week_meal_ingredients")


class GroceryItem(Base):
    __tablename__ = "grocery_items"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    week_id: Mapped[str] = mapped_column(ForeignKey("weeks.id", ondelete="CASCADE"), nullable=False)
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
    total_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    unit: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    quantity_text: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    category: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    source_meals: Mapped[str] = mapped_column(Text, default="", nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    review_flag: Mapped[str] = mapped_column(Text, default="", nullable=False)
    resolution_status: Mapped[str] = mapped_column(String(24), default="unresolved", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    week: Mapped["Week"] = relationship(back_populates="grocery_items")
    base_ingredient: Mapped["BaseIngredient | None"] = relationship(back_populates="grocery_items")
    ingredient_variation: Mapped["IngredientVariation | None"] = relationship(back_populates="grocery_items")
    retailer_prices: Mapped[list["RetailerPrice"]] = relationship(
        back_populates="grocery_item",
        cascade="all, delete-orphan",
    )
    feedback_entries: Mapped[list["FeedbackEntry"]] = relationship(back_populates="grocery_item")


class RetailerPrice(Base):
    __tablename__ = "retailer_prices"
    __table_args__ = (UniqueConstraint("grocery_item_id", "retailer", name="uq_item_retailer"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    grocery_item_id: Mapped[str] = mapped_column(
        ForeignKey("grocery_items.id", ondelete="CASCADE"), nullable=False
    )
    retailer: Mapped[str] = mapped_column(String(40), nullable=False)
    status: Mapped[str] = mapped_column(String(32), default="unavailable", nullable=False)
    store_name: Mapped[str] = mapped_column(String(255), default="", nullable=False)
    product_name: Mapped[str] = mapped_column(String(255), default="", nullable=False)
    package_size: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    unit_price: Mapped[float | None] = mapped_column(Float, nullable=True)
    line_price: Mapped[float | None] = mapped_column(Float, nullable=True)
    product_url: Mapped[str] = mapped_column(Text, default="", nullable=False)
    availability: Mapped[str] = mapped_column(String(255), default="", nullable=False)
    candidate_score: Mapped[float | None] = mapped_column(Float, nullable=True)
    review_note: Mapped[str] = mapped_column(Text, default="", nullable=False)
    raw_query: Mapped[str] = mapped_column(String(255), default="", nullable=False)
    scraped_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    grocery_item: Mapped["GroceryItem"] = relationship(back_populates="retailer_prices")


class WeekChangeBatch(Base):
    __tablename__ = "week_change_batches"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    week_id: Mapped[str] = mapped_column(ForeignKey("weeks.id", ondelete="CASCADE"), nullable=False)
    actor_type: Mapped[str] = mapped_column(String(40), default="system", nullable=False)
    actor_label: Mapped[str] = mapped_column(String(80), default="", nullable=False)
    summary: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)

    week: Mapped["Week"] = relationship(back_populates="change_batches")
    events: Mapped[list["WeekChangeEvent"]] = relationship(
        back_populates="batch",
        cascade="all, delete-orphan",
        order_by=lambda: (WeekChangeEvent.entity_type, WeekChangeEvent.field_name),
    )


class WeekChangeEvent(Base):
    __tablename__ = "week_change_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    batch_id: Mapped[str] = mapped_column(ForeignKey("week_change_batches.id", ondelete="CASCADE"), nullable=False)
    entity_type: Mapped[str] = mapped_column(String(40), nullable=False)
    entity_id: Mapped[str] = mapped_column(String(36), default="", nullable=False)
    field_name: Mapped[str] = mapped_column(String(80), nullable=False)
    before_value: Mapped[str] = mapped_column(Text, default="", nullable=False)
    after_value: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)

    batch: Mapped["WeekChangeBatch"] = relationship(back_populates="events")


class FeedbackEntry(Base):
    __tablename__ = "feedback_entries"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    week_id: Mapped[str] = mapped_column(ForeignKey("weeks.id", ondelete="CASCADE"), nullable=False)
    meal_id: Mapped[str | None] = mapped_column(ForeignKey("week_meals.id", ondelete="SET NULL"), nullable=True)
    grocery_item_id: Mapped[str | None] = mapped_column(
        ForeignKey("grocery_items.id", ondelete="SET NULL"), nullable=True
    )
    target_type: Mapped[str] = mapped_column(String(40), nullable=False)
    target_name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), index=True, nullable=False)
    retailer: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    sentiment: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    reason_codes: Mapped[str] = mapped_column(Text, default="[]", nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    source: Mapped[str] = mapped_column(String(40), default="ui", nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    week: Mapped["Week"] = relationship(back_populates="feedback_entries")
    meal: Mapped["WeekMeal | None"] = relationship(back_populates="feedback_entries")
    grocery_item: Mapped["GroceryItem | None"] = relationship(back_populates="feedback_entries")


class ExportRun(Base):
    __tablename__ = "export_runs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    week_id: Mapped[str] = mapped_column(ForeignKey("weeks.id", ondelete="CASCADE"), nullable=False)
    destination: Mapped[str] = mapped_column(String(40), nullable=False)
    export_type: Mapped[str] = mapped_column(String(40), nullable=False)
    status: Mapped[str] = mapped_column(String(32), default="pending", nullable=False)
    payload_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    item_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    error: Mapped[str] = mapped_column(Text, default="", nullable=False)
    external_ref: Mapped[str] = mapped_column(String(255), default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    week: Mapped["Week"] = relationship(back_populates="export_runs")
    items: Mapped[list["ExportItem"]] = relationship(
        back_populates="export_run",
        cascade="all, delete-orphan",
        order_by=lambda: ExportItem.sort_order,
    )


class ExportItem(Base):
    __tablename__ = "export_items"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    export_run_id: Mapped[str] = mapped_column(ForeignKey("export_runs.id", ondelete="CASCADE"), nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    list_name: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    metadata_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    status: Mapped[str] = mapped_column(String(32), default="pending", nullable=False)

    export_run: Mapped["ExportRun"] = relationship(back_populates="items")


class PricingRun(Base):
    __tablename__ = "pricing_runs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    week_id: Mapped[str] = mapped_column(ForeignKey("weeks.id", ondelete="CASCADE"), nullable=False)
    status: Mapped[str] = mapped_column(String(32), default="pending", nullable=False)
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    item_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    totals_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    error: Mapped[str] = mapped_column(Text, default="", nullable=False)

    week: Mapped["Week"] = relationship(back_populates="pricing_runs")
