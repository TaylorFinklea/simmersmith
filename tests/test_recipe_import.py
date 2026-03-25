from __future__ import annotations

from app.services.recipe_import import parse_ingredient_line


def test_parse_ingredient_line_handles_common_quantities_and_units() -> None:
    spaghetti = parse_ingredient_line("1 lb spaghetti")
    assert spaghetti.ingredient_name == "spaghetti"
    assert spaghetti.quantity == 1
    assert spaghetti.unit == "lb"
    assert spaghetti.prep == ""
    assert spaghetti.notes == ""
    assert spaghetti.normalized_name == "spaghetti"

    lemons = parse_ingredient_line("2 lemons")
    assert lemons.ingredient_name == "lemons"
    assert lemons.quantity == 2
    assert lemons.unit == ""
    assert lemons.prep == ""
    assert lemons.notes == ""


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


def test_parse_ingredient_line_preserves_package_notes_and_modifier_notes() -> None:
    tomatoes = parse_ingredient_line("1 (14-ounce) can diced tomatoes, drained")
    assert tomatoes.ingredient_name == "diced tomatoes"
    assert tomatoes.quantity == 1
    assert tomatoes.unit == "can"
    assert tomatoes.prep == "drained"
    assert tomatoes.notes == "14-ounce"

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
