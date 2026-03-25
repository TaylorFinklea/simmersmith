from __future__ import annotations

from app.services.recipe_import import import_recipe_from_text, parse_ingredient_line


def test_parse_ingredient_line_handles_common_quantities_and_units() -> None:
    spaghetti = parse_ingredient_line("1 lb spaghetti")
    assert spaghetti.ingredient_name == "spaghetti"
    assert spaghetti.quantity == 1
    assert spaghetti.unit == "lb"
    assert spaghetti.prep == ""
    assert spaghetti.notes == ""
    assert spaghetti.category == "Pantry"
    assert spaghetti.normalized_name == "spaghetti"

    lemons = parse_ingredient_line("2 lemons")
    assert lemons.ingredient_name == "lemons"
    assert lemons.quantity == 2
    assert lemons.unit == ""
    assert lemons.prep == ""
    assert lemons.notes == ""
    assert lemons.category == "Produce"


def test_parse_ingredient_line_handles_prep_phrases_and_mixed_fractions() -> None:
    milk = parse_ingredient_line("1 3/4 cups milk, lukewarm")
    assert milk.ingredient_name == "milk"
    assert milk.quantity == 1.75
    assert milk.unit == "cup"
    assert milk.prep == "lukewarm"

    butter = parse_ingredient_line("4 tbsp melted butter")
    assert butter.ingredient_name == "butter"
    assert butter.quantity == 4
    assert butter.unit == "tbsp"
    assert butter.prep == "melted"

    garlic = parse_ingredient_line("2 cloves garlic, minced")
    assert garlic.ingredient_name == "garlic"
    assert garlic.quantity == 2
    assert garlic.unit == "clove"
    assert garlic.prep == "minced"
    assert garlic.category == "Produce"


def test_parse_ingredient_line_preserves_package_notes_and_modifier_notes() -> None:
    tomatoes = parse_ingredient_line("1 (14-ounce) can diced tomatoes, drained")
    assert tomatoes.ingredient_name == "diced tomatoes"
    assert tomatoes.quantity == 1
    assert tomatoes.unit == "can"
    assert tomatoes.prep == "drained"
    assert tomatoes.notes == "14-ounce"
    assert tomatoes.category == "Produce"

    salt = parse_ingredient_line("salt to taste")
    assert salt.ingredient_name == "salt"
    assert salt.quantity is None
    assert salt.unit == ""
    assert salt.prep == ""
    assert salt.notes == "to taste"


def test_parse_ingredient_line_falls_back_without_false_unit_parse() -> None:
    pepper = parse_ingredient_line("freshly ground black pepper")
    assert pepper.ingredient_name == "freshly ground black pepper"
    assert pepper.quantity is None
    assert pepper.unit == ""
    assert pepper.prep == ""
    assert pepper.notes == ""
    assert pepper.category == "Pantry"


def test_parse_ingredient_line_handles_alternative_notes_and_category_inference() -> None:
    roast = parse_ingredient_line("3 pounds beef chuck roast")
    assert roast.ingredient_name == "beef chuck roast"
    assert roast.quantity == 3
    assert roast.unit == "lb"
    assert roast.category == "Meat"

    mustard = parse_ingredient_line("2 Tablespoons yellow mustard")
    assert mustard.ingredient_name == "yellow mustard"
    assert mustard.quantity == 2
    assert mustard.unit == "tbsp"
    assert mustard.category == "Condiments"

    rub = parse_ingredient_line(
        "3 Tablespoons Hey Grill Hey Beef Rub (or 1 Tablespoon each coarse salt, ground black pepper, and garlic powder)"
    )
    assert rub.ingredient_name == "Hey Grill Hey Beef Rub"
    assert rub.quantity == 3
    assert rub.unit == "tbsp"
    assert rub.category == "Pantry"
    assert rub.notes == "or 1 Tablespoon each coarse salt, ground black pepper, and garlic powder"

    sauce = parse_ingredient_line(
        "½ cup Hey Grill Hey Everything BBQ Sauce (or your favorite ketchup-based BBQ sauce)"
    )
    assert sauce.ingredient_name == "Hey Grill Hey Everything BBQ Sauce"
    assert sauce.quantity == 0.5
    assert sauce.unit == "cup"
    assert sauce.category == "Condiments"
    assert sauce.notes == "or your favorite ketchup-based BBQ sauce"


def test_import_recipe_from_text_infers_sections_when_headings_are_missing() -> None:
    imported = import_recipe_from_text(
        """
        Whole Wheat Waffles
        Servings: 4
        2 cups whole wheat flour
        2 eggs
        1 3/4 cups milk
        4 tbsp melted butter
        1. Whisk the dry ingredients together.
        2. Add the wet ingredients and stir until combined.
        3. Cook in a waffle iron until crisp.
        """.strip(),
        source_label="Family recipe card",
    )

    assert imported.name == "Whole Wheat Waffles"
    assert [ingredient.ingredient_name for ingredient in imported.ingredients] == [
        "whole wheat flour",
        "eggs",
        "milk",
        "butter",
    ]
    assert [step.instruction for step in imported.steps] == [
        "Whisk the dry ingredients together.",
        "Add the wet ingredients and stir until combined.",
        "Cook in a waffle iron until crisp.",
    ]


def test_import_recipe_from_text_strips_page_markers_and_joins_wrapped_lines() -> None:
    imported = import_recipe_from_text(
        """
        Best Pancakes
        Page 1 of 2
        Ingredients
        1 (14-ounce)
        can diced tomatoes, drained
        1 cup milk,
        lukewarm
        Instructions
        1. Stir everything together.
        2/2
        2. Simmer for 10 minutes.
        """.strip()
    )

    assert [ingredient.ingredient_name for ingredient in imported.ingredients] == ["diced tomatoes", "milk"]
    assert imported.ingredients[0].notes == "14-ounce"
    assert imported.ingredients[1].prep == "lukewarm"
    assert [step.instruction for step in imported.steps] == [
        "Stir everything together.",
        "Simmer for 10 minutes.",
    ]
