"""Event Plans — one-off meal plans for occasions (holidays, birthdays,
parties). Mirrors the Week/WeekMeal/GroceryItem structure but parallel
to it: events can exist independently of any week, and their grocery
lists can optionally be merged into a week's grocery list.
"""
from __future__ import annotations

from datetime import date, datetime
from typing import TYPE_CHECKING

from sqlalchemy import (
    Boolean,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models._base import new_id, utcnow

if TYPE_CHECKING:
    from app.models.catalog import BaseIngredient, IngredientVariation
    from app.models.recipe import Recipe
    from app.models.week import GroceryItem, Week


class Guest(Base):
    __tablename__ = "guests"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    # Named `relationship_label` in Python to avoid shadowing SQLAlchemy's
    # `relationship()` import used below. DB column name stays readable
    # via the `name=` arg.
    relationship_label: Mapped[str] = mapped_column(
        "relationship", String(120), default="", nullable=False
    )
    dietary_notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    allergies: Mapped[str] = mapped_column(Text, default="", nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    attendances: Mapped[list["EventAttendee"]] = relationship(
        back_populates="guest",
        cascade="all, delete-orphan",
    )


class Event(Base):
    __tablename__ = "events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    event_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    occasion: Mapped[str] = mapped_column(String(64), default="other", nullable=False)
    attendee_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    status: Mapped[str] = mapped_column(String(24), default="draft", nullable=False)
    linked_week_id: Mapped[str | None] = mapped_column(
        ForeignKey("weeks.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    attendees: Mapped[list["EventAttendee"]] = relationship(
        back_populates="event",
        cascade="all, delete-orphan",
        order_by=lambda: EventAttendee.created_at,
    )
    meals: Mapped[list["EventMeal"]] = relationship(
        back_populates="event",
        cascade="all, delete-orphan",
        order_by=lambda: (EventMeal.sort_order, EventMeal.created_at),
    )
    grocery_items: Mapped[list["EventGroceryItem"]] = relationship(
        back_populates="event",
        cascade="all, delete-orphan",
        order_by=lambda: (EventGroceryItem.category, EventGroceryItem.ingredient_name),
    )
    linked_week: Mapped["Week | None"] = relationship()


class EventAttendee(Base):
    __tablename__ = "event_attendees"

    event_id: Mapped[str] = mapped_column(
        ForeignKey("events.id", ondelete="CASCADE"), primary_key=True
    )
    guest_id: Mapped[str] = mapped_column(
        ForeignKey("guests.id", ondelete="CASCADE"), primary_key=True
    )
    plus_ones: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)

    event: Mapped["Event"] = relationship(back_populates="attendees")
    guest: Mapped["Guest"] = relationship(back_populates="attendances")


class EventMeal(Base):
    __tablename__ = "event_meals"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    event_id: Mapped[str] = mapped_column(
        ForeignKey("events.id", ondelete="CASCADE"), nullable=False
    )
    role: Mapped[str] = mapped_column(String(32), default="main", nullable=False)
    recipe_id: Mapped[str | None] = mapped_column(
        ForeignKey("recipes.id", ondelete="SET NULL"), nullable=True
    )
    recipe_name: Mapped[str] = mapped_column(String(255), nullable=False)
    servings: Mapped[float | None] = mapped_column(Float, nullable=True)
    scale_multiplier: Mapped[float] = mapped_column(Float, default=1.0, nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    ai_generated: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    approved: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    # JSON list of guest_ids this dish is known to work for. Empty list
    # means the dish is unconstrained / works for everyone.
    constraint_coverage: Mapped[str] = mapped_column(Text, default="[]", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    event: Mapped["Event"] = relationship(back_populates="meals")
    recipe: Mapped["Recipe | None"] = relationship()
    inline_ingredients: Mapped[list["EventMealIngredient"]] = relationship(
        back_populates="event_meal",
        cascade="all, delete-orphan",
        order_by=lambda: EventMealIngredient.ingredient_name,
    )


class EventMealIngredient(Base):
    __tablename__ = "event_meal_ingredients"

    id: Mapped[str] = mapped_column(String(140), primary_key=True)
    event_meal_id: Mapped[str] = mapped_column(
        ForeignKey("event_meals.id", ondelete="CASCADE"), nullable=False
    )
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

    event_meal: Mapped["EventMeal"] = relationship(back_populates="inline_ingredients")
    base_ingredient: Mapped["BaseIngredient | None"] = relationship()
    ingredient_variation: Mapped["IngredientVariation | None"] = relationship()


class EventGroceryItem(Base):
    __tablename__ = "event_grocery_items"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    event_id: Mapped[str] = mapped_column(
        ForeignKey("events.id", ondelete="CASCADE"), nullable=False
    )
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
    merged_into_week_id: Mapped[str | None] = mapped_column(
        ForeignKey("weeks.id", ondelete="SET NULL"), nullable=True
    )
    merged_into_grocery_item_id: Mapped[str | None] = mapped_column(
        ForeignKey("grocery_items.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    event: Mapped["Event"] = relationship(back_populates="grocery_items")
    base_ingredient: Mapped["BaseIngredient | None"] = relationship()
    ingredient_variation: Mapped["IngredientVariation | None"] = relationship()
    merged_into_grocery_item: Mapped["GroceryItem | None"] = relationship()
