from __future__ import annotations

import re
from datetime import date
from dataclasses import dataclass

from app.schemas import RecipeIngredientPayload, RecipePayload, RecipeStepPayload


@dataclass(frozen=True)
class VariationRule:
    terms: tuple[str, ...]
    replacement: str
    rationale: str


@dataclass(frozen=True)
class VariationPreset:
    key: str
    label: str
    title_prefix: str
    extra_tags: tuple[str, ...]
    guidance_note: str
    ingredient_rules: tuple[VariationRule, ...]


@dataclass(frozen=True)
class SuggestionPreset:
    key: str
    label: str
    title_prefix: str
    meal_type: str
    rationale_note: str
    extra_tags: tuple[str, ...] = ()
    variation_goal: str | None = None


@dataclass(frozen=True)
class CompanionPreset:
    option_id: str
    label: str
    name: str
    rationale: str
    meal_type: str
    cuisine: str
    tags: tuple[str, ...]
    notes: str
    ingredients: tuple[RecipeIngredientPayload, ...]
    steps: tuple[RecipeStepPayload, ...]


VARIATION_PRESETS: tuple[VariationPreset, ...] = (
    VariationPreset(
        key="low_carb",
        label="Low-Carb",
        title_prefix="Low-Carb",
        extra_tags=("low-carb",),
        guidance_note="Reduce starch-heavy ingredients and keep the same flavor profile where possible.",
        ingredient_rules=(
            VariationRule(("spaghetti", "linguine", "fettuccine", "pasta", "noodle"), "zucchini noodles", "Swap noodles for zucchini noodles."),
            VariationRule(("rice",), "cauliflower rice", "Replace rice with cauliflower rice."),
            VariationRule(("potato", "potatoes"), "roasted cauliflower", "Replace potatoes with roasted cauliflower."),
            VariationRule(("tortilla", "wrap", "bun", "bread"), "lettuce wraps", "Swap bread-heavy components for lettuce wraps."),
        ),
    ),
    VariationPreset(
        key="dairy_free",
        label="Dairy-Free",
        title_prefix="Dairy-Free",
        extra_tags=("dairy-free",),
        guidance_note="Replace dairy with neutral, easy-to-find alternatives and keep the texture balanced.",
        ingredient_rules=(
            VariationRule(("milk", "whole milk", "skim milk", "buttermilk"), "unsweetened oat milk", "Use oat milk in place of dairy milk."),
            VariationRule(("butter",), "olive oil", "Use olive oil instead of butter."),
            VariationRule(("cream", "half-and-half"), "full-fat coconut milk", "Replace cream with coconut milk."),
            VariationRule(("cheese", "parmesan", "mozzarella", "cheddar"), "dairy-free cheese", "Use a dairy-free cheese alternative."),
            VariationRule(("yogurt", "sour cream"), "dairy-free yogurt", "Swap cultured dairy for dairy-free yogurt."),
        ),
    ),
    VariationPreset(
        key="gluten_free",
        label="Gluten-Free",
        title_prefix="Gluten-Free",
        extra_tags=("gluten-free",),
        guidance_note="Replace wheat-based ingredients with common gluten-free alternatives.",
        ingredient_rules=(
            VariationRule(("flour", "all-purpose flour", "wheat flour"), "gluten-free flour blend", "Swap wheat flour for a gluten-free flour blend."),
            VariationRule(("soy sauce",), "tamari", "Use tamari instead of soy sauce."),
            VariationRule(("breadcrumbs", "bread crumbs"), "gluten-free breadcrumbs", "Replace breadcrumbs with a gluten-free version."),
            VariationRule(("pasta", "spaghetti", "linguine", "fettuccine"), "gluten-free pasta", "Use gluten-free pasta."),
            VariationRule(("tortilla", "wrap"), "corn tortilla", "Use a gluten-free tortilla option."),
        ),
    ),
    VariationPreset(
        key="vegetarian",
        label="Vegetarian",
        title_prefix="Vegetarian",
        extra_tags=("vegetarian",),
        guidance_note="Replace meat with satisfying vegetarian protein and umami-friendly ingredients.",
        ingredient_rules=(
            VariationRule(("chicken", "chicken breast", "chicken thighs"), "extra-firm tofu", "Replace chicken with extra-firm tofu."),
            VariationRule(("ground beef", "beef", "steak"), "lentils and mushrooms", "Replace beef with lentils and mushrooms."),
            VariationRule(("ground turkey", "turkey"), "seasoned chickpeas", "Replace turkey with seasoned chickpeas."),
            VariationRule(("pork", "sausage", "bacon"), "smoked mushrooms", "Use smoked mushrooms for savory depth."),
        ),
    ),
    VariationPreset(
        key="kid_friendly",
        label="Kid-Friendly",
        title_prefix="Kid-Friendly",
        extra_tags=("kid-friendly",),
        guidance_note="Tone down heat, simplify flavors, and keep textures approachable.",
        ingredient_rules=(
            VariationRule(("jalapeno", "jalapeño", "serrano", "chili", "red pepper flakes", "hot sauce"), "mild bell pepper", "Swap heat-heavy ingredients for a milder pepper."),
            VariationRule(("onion"), "finely diced onion", "Use smaller onion pieces for a softer texture."),
        ),
    ),
    VariationPreset(
        key="pantry_friendly",
        label="Pantry-Friendly",
        title_prefix="Pantry-Friendly",
        extra_tags=("pantry-friendly",),
        guidance_note="Favor shelf-stable or freezer-friendly swaps that are easier to keep on hand.",
        ingredient_rules=(
            VariationRule(("fresh basil", "fresh parsley", "fresh cilantro"), "dried herbs", "Use dried herbs instead of fresh."),
            VariationRule(("fresh lemon", "fresh lime"), "bottled lemon juice", "Use bottled citrus if needed."),
            VariationRule(("fresh garlic",), "garlic powder", "Swap fresh garlic for garlic powder."),
            VariationRule(("spinach", "broccoli", "peas"), "frozen vegetables", "Replace fresh vegetables with frozen alternatives."),
        ),
    ),
)

SUGGESTION_PRESETS: tuple[SuggestionPreset, ...] = (
    SuggestionPreset(
        key="weeknight_dinner",
        label="Weeknight Dinner",
        title_prefix="Weeknight",
        meal_type="dinner",
        rationale_note="Favor a reliable dinner idea pulled from your saved rotation.",
        extra_tags=("weeknight", "ai-suggested"),
    ),
    SuggestionPreset(
        key="breakfast_rotation",
        label="Breakfast Rotation",
        title_prefix="Breakfast",
        meal_type="breakfast",
        rationale_note="Keep breakfast ideas moving without losing the recipes you already trust.",
        extra_tags=("breakfast-rotation", "ai-suggested"),
    ),
    SuggestionPreset(
        key="lunchbox_friendly",
        label="Lunchbox Friendly",
        title_prefix="Lunchbox",
        meal_type="lunch",
        rationale_note="Start from a saved recipe that can translate into a portable lunch.",
        extra_tags=("portable-lunch", "ai-suggested"),
    ),
    SuggestionPreset(
        key="pantry_reset",
        label="Pantry Reset",
        title_prefix="Pantry-Friendly",
        meal_type="dinner",
        rationale_note="Use your existing recipe history, but bias toward easier pantry-friendly swaps.",
        extra_tags=("pantry-friendly", "ai-suggested"),
        variation_goal="Pantry-Friendly",
    ),
    SuggestionPreset(
        key="kid_friendly_dinner",
        label="Kid-Friendly Dinner",
        title_prefix="Kid-Friendly",
        meal_type="dinner",
        rationale_note="Start from a dinner your library already suggests is family-usable, then soften the edges.",
        extra_tags=("kid-friendly", "ai-suggested"),
        variation_goal="Kid-Friendly",
    ),
)

COMPANION_LIBRARY: dict[str, tuple[CompanionPreset, CompanionPreset, CompanionPreset]] = {
    "neutral": (
        CompanionPreset(
            option_id="vegetable-side",
            label="Vegetable Side",
            name="Roasted Lemon Green Beans",
            rationale="A bright vegetable side keeps richer mains from feeling heavy.",
            meal_type="dinner",
            cuisine="",
            tags=("companion", "companion-side", "vegetable-side", "ai-suggested"),
            notes="AI companion note: Built as a lighter vegetable side to balance the anchor recipe.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="green beans", quantity=1, unit="lb", category="Produce"),
                RecipeIngredientPayload(ingredient_name="olive oil", quantity=1, unit="tbsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="lemon zest", quantity=1, unit="tsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="kosher salt", quantity=0.5, unit="tsp", category="Pantry"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Toss the green beans with olive oil, lemon zest, and salt."),
                RecipeStepPayload(sort_order=2, instruction="Roast until tender and lightly blistered, then serve warm."),
            ),
        ),
        CompanionPreset(
            option_id="starch-side",
            label="Starch Side",
            name="Herbed Rice Pilaf",
            rationale="A simple starch side rounds out the plate without competing with the main recipe.",
            meal_type="dinner",
            cuisine="",
            tags=("companion", "companion-side", "starch-side", "ai-suggested"),
            notes="AI companion note: Built as a neutral starch side to make the meal feel complete.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="long-grain rice", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="chicken broth", quantity=2, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="butter", quantity=1, unit="tbsp", category="Dairy"),
                RecipeIngredientPayload(ingredient_name="parsley", quantity=2, unit="tbsp", prep="chopped", category="Produce"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Toast the rice in butter until lightly fragrant."),
                RecipeStepPayload(sort_order=2, instruction="Simmer with broth until tender, then fold in chopped parsley."),
            ),
        ),
        CompanionPreset(
            option_id="sauce",
            label="Sauce / Drizzle",
            name="Lemon Herb Yogurt Sauce",
            rationale="A cool sauce gives the meal a second texture and an easy finishing element.",
            meal_type="dinner",
            cuisine="",
            tags=("companion", "companion-sauce", "ai-suggested"),
            notes="AI companion note: Built as a flexible finishing sauce that works with many savory mains.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="Greek yogurt", quantity=1, unit="cup", category="Dairy"),
                RecipeIngredientPayload(ingredient_name="lemon juice", quantity=1, unit="tbsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="olive oil", quantity=1, unit="tsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="parsley", quantity=1, unit="tbsp", prep="chopped", category="Produce"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Whisk the yogurt, lemon juice, olive oil, and parsley until smooth."),
                RecipeStepPayload(sort_order=2, instruction="Season to taste and spoon over the finished dish."),
            ),
        ),
    ),
    "barbecue": (
        CompanionPreset(
            option_id="vegetable-side",
            label="Vegetable Side",
            name="Tangy Pickle Slaw",
            rationale="Crunchy slaw cuts through smoky barbecue and keeps the plate from feeling too rich.",
            meal_type="dinner",
            cuisine="American",
            tags=("companion", "companion-side", "vegetable-side", "ai-suggested", "barbecue"),
            notes="AI companion note: Built to bring acidity and crunch alongside a smoky barbecue-style main.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="coleslaw mix", quantity=1, unit="bag", category="Produce"),
                RecipeIngredientPayload(ingredient_name="dill pickles", quantity=0.5, unit="cup", prep="chopped", category="Condiments"),
                RecipeIngredientPayload(ingredient_name="apple cider vinegar", quantity=2, unit="tbsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="mayonnaise", quantity=0.25, unit="cup", category="Condiments"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Whisk the mayonnaise and apple cider vinegar into a quick dressing."),
                RecipeStepPayload(sort_order=2, instruction="Fold in the slaw mix and chopped pickles, then chill before serving."),
            ),
        ),
        CompanionPreset(
            option_id="starch-side",
            label="Starch Side",
            name="Skillet Cornbread",
            rationale="Cornbread adds a classic barbecue-friendly starch without overlapping the main flavor too much.",
            meal_type="dinner",
            cuisine="American",
            tags=("companion", "companion-side", "starch-side", "ai-suggested", "barbecue"),
            notes="AI companion note: Built as a barbecue-friendly starch with enough structure for saucy mains.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="cornmeal", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="all-purpose flour", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="milk", quantity=1, unit="cup", category="Dairy"),
                RecipeIngredientPayload(ingredient_name="butter", quantity=4, unit="tbsp", prep="melted", category="Dairy"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Mix the batter until just combined and pour into a hot buttered skillet."),
                RecipeStepPayload(sort_order=2, instruction="Bake until golden and slice for serving alongside the main recipe."),
            ),
        ),
        CompanionPreset(
            option_id="sauce",
            label="Sauce / Drizzle",
            name="Sweet Heat Finishing Sauce",
            rationale="A glossy finishing sauce lets the main recipe stay central while giving each serving an easy boost.",
            meal_type="dinner",
            cuisine="American",
            tags=("companion", "companion-sauce", "ai-suggested", "barbecue"),
            notes="AI companion note: Built as a brush-on or drizzle sauce for smoked or roasted barbecue dishes.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="barbecue sauce", quantity=0.5, unit="cup", category="Condiments"),
                RecipeIngredientPayload(ingredient_name="apple cider vinegar", quantity=1, unit="tbsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="hot honey", quantity=1, unit="tbsp", category="Condiments"),
                RecipeIngredientPayload(ingredient_name="butter", quantity=1, unit="tbsp", category="Dairy"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Warm the barbecue sauce, vinegar, hot honey, and butter together until glossy."),
                RecipeStepPayload(sort_order=2, instruction="Brush or drizzle the sauce over the finished meat right before serving."),
            ),
        ),
    ),
    "italian": (
        CompanionPreset(
            option_id="vegetable-side",
            label="Vegetable Side",
            name="Garlic Roasted Broccolini",
            rationale="A fast green side keeps an Italian-style meal feeling lighter and cleaner.",
            meal_type="dinner",
            cuisine="Italian",
            tags=("companion", "companion-side", "vegetable-side", "ai-suggested", "italian"),
            notes="AI companion note: Built as a green vegetable side that fits an Italian-leaning dinner.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="broccolini", quantity=1, unit="lb", category="Produce"),
                RecipeIngredientPayload(ingredient_name="olive oil", quantity=1, unit="tbsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="garlic", quantity=2, unit="clove", prep="minced", category="Produce"),
                RecipeIngredientPayload(ingredient_name="parmesan", quantity=2, unit="tbsp", prep="grated", category="Dairy"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Toss the broccolini with olive oil and minced garlic."),
                RecipeStepPayload(sort_order=2, instruction="Roast until tender and finish with grated parmesan."),
            ),
        ),
        CompanionPreset(
            option_id="starch-side",
            label="Starch Side",
            name="Creamy Parmesan Polenta",
            rationale="Polenta gives the plate a soft starch that complements sauces without feeling redundant.",
            meal_type="dinner",
            cuisine="Italian",
            tags=("companion", "companion-side", "starch-side", "ai-suggested", "italian"),
            notes="AI companion note: Built as a creamy starch side that matches Italian-style mains.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="polenta", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="chicken broth", quantity=4, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="parmesan", quantity=0.5, unit="cup", prep="grated", category="Dairy"),
                RecipeIngredientPayload(ingredient_name="butter", quantity=2, unit="tbsp", category="Dairy"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Simmer the polenta in broth until thick and tender."),
                RecipeStepPayload(sort_order=2, instruction="Stir in butter and parmesan just before serving."),
            ),
        ),
        CompanionPreset(
            option_id="sauce",
            label="Sauce / Drizzle",
            name="Basil Parsley Gremolata",
            rationale="A fresh herb topping adds brightness and contrast to richer Italian-style mains.",
            meal_type="dinner",
            cuisine="Italian",
            tags=("companion", "companion-sauce", "ai-suggested", "italian"),
            notes="AI companion note: Built as a bright finishing spoonful for roasted or braised mains.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="parsley", quantity=0.5, unit="cup", prep="chopped", category="Produce"),
                RecipeIngredientPayload(ingredient_name="basil", quantity=0.25, unit="cup", prep="chopped", category="Produce"),
                RecipeIngredientPayload(ingredient_name="lemon zest", quantity=1, unit="tsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="olive oil", quantity=2, unit="tbsp", category="Pantry"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Mix the parsley, basil, lemon zest, and olive oil together."),
                RecipeStepPayload(sort_order=2, instruction="Spoon over the finished dish right before serving."),
            ),
        ),
    ),
    "mexican": (
        CompanionPreset(
            option_id="vegetable-side",
            label="Vegetable Side",
            name="Charred Corn and Pepper Salad",
            rationale="A quick vegetable side adds freshness and a little sweetness next to spiced mains.",
            meal_type="dinner",
            cuisine="Mexican",
            tags=("companion", "companion-side", "vegetable-side", "ai-suggested", "mexican"),
            notes="AI companion note: Built as a fresh vegetable side for a Mexican-leaning main.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="corn kernels", quantity=2, unit="cup", category="Produce"),
                RecipeIngredientPayload(ingredient_name="red bell pepper", quantity=1, unit="", prep="diced", category="Produce"),
                RecipeIngredientPayload(ingredient_name="lime juice", quantity=1, unit="tbsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="cilantro", quantity=2, unit="tbsp", prep="chopped", category="Produce"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Cook the corn and bell pepper in a hot skillet until lightly charred."),
                RecipeStepPayload(sort_order=2, instruction="Finish with lime juice and chopped cilantro."),
            ),
        ),
        CompanionPreset(
            option_id="starch-side",
            label="Starch Side",
            name="Cilantro Lime Rice",
            rationale="Rice is an easy starch side that stays useful across tacos, bowls, and roasted proteins.",
            meal_type="dinner",
            cuisine="Mexican",
            tags=("companion", "companion-side", "starch-side", "ai-suggested", "mexican"),
            notes="AI companion note: Built as a versatile starch side for a Mexican-style dinner.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="white rice", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="chicken broth", quantity=2, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="lime juice", quantity=1, unit="tbsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="cilantro", quantity=0.25, unit="cup", prep="chopped", category="Produce"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Cook the rice in broth until tender."),
                RecipeStepPayload(sort_order=2, instruction="Fold in the lime juice and chopped cilantro before serving."),
            ),
        ),
        CompanionPreset(
            option_id="sauce",
            label="Sauce / Drizzle",
            name="Avocado Crema",
            rationale="A cool, creamy sauce softens heat and gives the meal an easy finishing component.",
            meal_type="dinner",
            cuisine="Mexican",
            tags=("companion", "companion-sauce", "ai-suggested", "mexican"),
            notes="AI companion note: Built as a cooling sauce for a Mexican-leaning main or side.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="avocado", quantity=1, unit="", category="Produce"),
                RecipeIngredientPayload(ingredient_name="sour cream", quantity=0.5, unit="cup", category="Dairy"),
                RecipeIngredientPayload(ingredient_name="lime juice", quantity=1, unit="tbsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="cilantro", quantity=1, unit="tbsp", prep="chopped", category="Produce"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Blend the avocado, sour cream, lime juice, and cilantro until smooth."),
                RecipeStepPayload(sort_order=2, instruction="Thin with a splash of water if needed and spoon over the meal."),
            ),
        ),
    ),
    "thai": (
        CompanionPreset(
            option_id="vegetable-side",
            label="Vegetable Side",
            name="Cucumber Herb Salad",
            rationale="A cold vegetable side offsets richer Thai-style mains and keeps the flavors bright.",
            meal_type="dinner",
            cuisine="Thai",
            tags=("companion", "companion-side", "vegetable-side", "ai-suggested", "thai"),
            notes="AI companion note: Built as a cooling vegetable side for a Thai-leaning main.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="cucumber", quantity=2, unit="", prep="thinly sliced", category="Produce"),
                RecipeIngredientPayload(ingredient_name="rice vinegar", quantity=1, unit="tbsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="lime juice", quantity=1, unit="tbsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="cilantro", quantity=2, unit="tbsp", prep="chopped", category="Produce"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Toss the sliced cucumber with rice vinegar and lime juice."),
                RecipeStepPayload(sort_order=2, instruction="Finish with chopped cilantro and chill until serving."),
            ),
        ),
        CompanionPreset(
            option_id="starch-side",
            label="Starch Side",
            name="Coconut Jasmine Rice",
            rationale="A softly flavored starch side helps carry bold sauces without overwhelming them.",
            meal_type="dinner",
            cuisine="Thai",
            tags=("companion", "companion-side", "starch-side", "ai-suggested", "thai"),
            notes="AI companion note: Built as a Thai-friendly starch side with a little richness.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="jasmine rice", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="coconut milk", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="water", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="salt", quantity=0.5, unit="tsp", category="Pantry"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Combine the rice, coconut milk, water, and salt in a saucepan."),
                RecipeStepPayload(sort_order=2, instruction="Cook until the rice is tender and fluffy."),
            ),
        ),
        CompanionPreset(
            option_id="sauce",
            label="Sauce / Drizzle",
            name="Peanut Lime Sauce",
            rationale="A nutty sauce gives the meal a useful extra layer without changing the core recipe.",
            meal_type="dinner",
            cuisine="Thai",
            tags=("companion", "companion-sauce", "ai-suggested", "thai"),
            notes="AI companion note: Built as a Thai-leaning drizzle for noodles, grilled proteins, or vegetables.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="peanut butter", quantity=0.25, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="lime juice", quantity=1, unit="tbsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="soy sauce", quantity=1, unit="tbsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="warm water", quantity=2, unit="tbsp", category="Pantry"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Whisk the peanut butter, lime juice, soy sauce, and warm water together."),
                RecipeStepPayload(sort_order=2, instruction="Thin as needed for drizzling and serve alongside the meal."),
            ),
        ),
    ),
    "middle_eastern": (
        CompanionPreset(
            option_id="vegetable-side",
            label="Vegetable Side",
            name="Cucumber Tomato Salad",
            rationale="A sharp vegetable salad keeps spiced roasted or grilled mains feeling balanced.",
            meal_type="dinner",
            cuisine="Middle Eastern",
            tags=("companion", "companion-side", "vegetable-side", "ai-suggested", "middle-eastern"),
            notes="AI companion note: Built as a crisp, fresh salad for a Middle Eastern-leaning main.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="cucumber", quantity=1, unit="", prep="diced", category="Produce"),
                RecipeIngredientPayload(ingredient_name="tomatoes", quantity=2, unit="", prep="diced", category="Produce"),
                RecipeIngredientPayload(ingredient_name="lemon juice", quantity=1, unit="tbsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="mint", quantity=1, unit="tbsp", prep="chopped", category="Produce"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Combine the cucumber and tomatoes in a bowl."),
                RecipeStepPayload(sort_order=2, instruction="Dress with lemon juice and chopped mint just before serving."),
            ),
        ),
        CompanionPreset(
            option_id="starch-side",
            label="Starch Side",
            name="Turmeric Rice Pilaf",
            rationale="A warm rice side supports grilled and braised mains without crowding the main spice profile.",
            meal_type="dinner",
            cuisine="Middle Eastern",
            tags=("companion", "companion-side", "starch-side", "ai-suggested", "middle-eastern"),
            notes="AI companion note: Built as a lightly spiced rice side for a Middle Eastern-leaning main.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="basmati rice", quantity=1, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="chicken broth", quantity=2, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="turmeric", quantity=0.5, unit="tsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="butter", quantity=1, unit="tbsp", category="Dairy"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Toast the rice in butter with turmeric."),
                RecipeStepPayload(sort_order=2, instruction="Add broth and cook until the rice is tender and fragrant."),
            ),
        ),
        CompanionPreset(
            option_id="sauce",
            label="Sauce / Drizzle",
            name="Tahini Lemon Sauce",
            rationale="A creamy tahini sauce gives the meal an easy finish and ties together grilled or roasted flavors.",
            meal_type="dinner",
            cuisine="Middle Eastern",
            tags=("companion", "companion-sauce", "ai-suggested", "middle-eastern"),
            notes="AI companion note: Built as a creamy finishing sauce for a Middle Eastern-style meal.",
            ingredients=(
                RecipeIngredientPayload(ingredient_name="tahini", quantity=0.25, unit="cup", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="lemon juice", quantity=2, unit="tbsp", category="Produce"),
                RecipeIngredientPayload(ingredient_name="warm water", quantity=2, unit="tbsp", category="Pantry"),
                RecipeIngredientPayload(ingredient_name="garlic", quantity=1, unit="clove", prep="minced", category="Produce"),
            ),
            steps=(
                RecipeStepPayload(sort_order=1, instruction="Whisk the tahini, lemon juice, warm water, and garlic until smooth."),
                RecipeStepPayload(sort_order=2, instruction="Adjust the texture as needed and drizzle over the meal."),
            ),
        ),
    ),
}


def _normalized_goal(goal: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", goal.lower()).strip()


def _normalized_text(*values: str) -> str:
    joined = " ".join(value for value in values if value)
    return re.sub(r"[^a-z0-9]+", " ", joined.lower()).strip()


def resolve_variation_preset(goal: str) -> VariationPreset:
    normalized = _normalized_goal(goal)
    keyword_map = {
        "low carb": "low_carb",
        "dairy free": "dairy_free",
        "gluten free": "gluten_free",
        "vegetarian": "vegetarian",
        "kid friendly": "kid_friendly",
        "kids": "kid_friendly",
        "pantry": "pantry_friendly",
    }
    for phrase, preset_key in keyword_map.items():
        if phrase in normalized:
            return next(preset for preset in VARIATION_PRESETS if preset.key == preset_key)
    return next(preset for preset in VARIATION_PRESETS if preset.key == "pantry_friendly")


def resolve_suggestion_preset(goal: str) -> SuggestionPreset:
    normalized = _normalized_goal(goal)
    keyword_map = {
        "weeknight": "weeknight_dinner",
        "dinner": "weeknight_dinner",
        "breakfast": "breakfast_rotation",
        "lunch": "lunchbox_friendly",
        "lunchbox": "lunchbox_friendly",
        "portable": "lunchbox_friendly",
        "pantry": "pantry_reset",
        "kid": "kid_friendly_dinner",
        "family": "kid_friendly_dinner",
    }
    for phrase, preset_key in keyword_map.items():
        if phrase in normalized:
            return next(preset for preset in SUGGESTION_PRESETS if preset.key == preset_key)
    return next(preset for preset in SUGGESTION_PRESETS if preset.key == "weeknight_dinner")


def _replace_term(text: str, rule: VariationRule) -> str:
    updated = text
    for term in sorted(rule.terms, key=len, reverse=True):
        updated = re.sub(re.escape(term), rule.replacement, updated, flags=re.IGNORECASE)
    return updated


def _transform_ingredient(
    ingredient: RecipeIngredientPayload,
    preset: VariationPreset,
) -> tuple[RecipeIngredientPayload, list[str]]:
    updated_name = ingredient.ingredient_name
    changes: list[str] = []
    for rule in preset.ingredient_rules:
        if any(term in ingredient.ingredient_name.lower() for term in rule.terms):
            replaced_name = _replace_term(updated_name, rule)
            if replaced_name != updated_name:
                updated_name = replaced_name
                changes.append(rule.rationale)

    return (
        RecipeIngredientPayload(
            ingredient_id=None,
            ingredient_name=updated_name,
            normalized_name=ingredient.normalized_name,
            quantity=ingredient.quantity,
            unit=ingredient.unit,
            prep=ingredient.prep,
            category=ingredient.category,
            notes=ingredient.notes,
        ),
        changes,
    )


def _transform_step(step: RecipeStepPayload, preset: VariationPreset) -> RecipeStepPayload:
    updated_instruction = step.instruction
    for rule in preset.ingredient_rules:
        updated_instruction = _replace_term(updated_instruction, rule)

    return RecipeStepPayload(
        step_id=None,
        sort_order=step.sort_order,
        instruction=updated_instruction,
        substeps=[_transform_step(substep, preset) for substep in step.substeps],
    )


def build_variation_draft(
    base_recipe: RecipePayload,
    *,
    goal: str,
) -> tuple[RecipePayload, str, str]:
    preset = resolve_variation_preset(goal)
    ingredient_changes: list[str] = []
    transformed_ingredients: list[RecipeIngredientPayload] = []
    for ingredient in base_recipe.ingredients:
        transformed, changes = _transform_ingredient(ingredient, preset)
        transformed_ingredients.append(transformed)
        ingredient_changes.extend(changes)

    transformed_steps = [_transform_step(step, preset) for step in base_recipe.steps]
    deduped_tags = list(dict.fromkeys([*base_recipe.tags, *preset.extra_tags]))
    distinct_changes = list(dict.fromkeys(ingredient_changes))
    variation_summary = preset.guidance_note
    if distinct_changes:
        variation_summary = f"{preset.guidance_note} Key swaps: {' '.join(distinct_changes[:3])}"

    existing_notes = base_recipe.notes.strip()
    combined_notes = variation_summary if not existing_notes else f"{existing_notes}\n\nAI variation note: {variation_summary}"

    draft = RecipePayload(
        recipe_id=None,
        recipe_template_id=base_recipe.recipe_template_id,
        base_recipe_id=base_recipe.base_recipe_id or base_recipe.recipe_id,
        name=f"{preset.title_prefix} {base_recipe.name}",
        meal_type=base_recipe.meal_type,
        cuisine=base_recipe.cuisine,
        servings=base_recipe.servings,
        prep_minutes=base_recipe.prep_minutes,
        cook_minutes=base_recipe.cook_minutes,
        tags=deduped_tags,
        instructions_summary=base_recipe.instructions_summary,
        favorite=False,
        source="ai_variation",
        source_label=base_recipe.source_label,
        source_url=base_recipe.source_url,
        notes=combined_notes,
        memories=base_recipe.memories,
        last_used=None,
        ingredients=transformed_ingredients,
        steps=transformed_steps,
        nutrition_summary=None,
    )
    rationale = variation_summary
    return draft, rationale, preset.label


def _days_since(value: date | None) -> int | None:
    if value is None:
        return None
    return (date.today() - value).days


def _meal_type_matches(recipe: RecipePayload, meal_type: str) -> bool:
    return recipe.meal_type.strip().lower() == meal_type.strip().lower()


def _recipe_score(recipe: RecipePayload, preset: SuggestionPreset) -> tuple[int, int, int, str]:
    days_since_last_used = _days_since(recipe.last_used)
    recency_score = 0 if days_since_last_used is None else max(0, 30 - min(days_since_last_used, 30))
    return (
        1 if _meal_type_matches(recipe, preset.meal_type) else 0,
        1 if recipe.favorite else 0,
        recency_score + min(len(recipe.tags), 3) + (1 if recipe.source_label else 0),
        recipe.name.lower(),
    )


def _prefixed_title(prefix: str, name: str) -> str:
    trimmed_prefix = prefix.strip()
    trimmed_name = name.strip()
    if trimmed_name.lower().startswith(trimmed_prefix.lower()):
        return trimmed_name
    return f"{trimmed_prefix} {trimmed_name}".strip()


def _infer_companion_library_key(recipe: RecipePayload) -> str:
    signal_text = _normalized_text(
        recipe.cuisine,
        " ".join(recipe.tags),
        recipe.source_label,
        " ".join(ingredient.ingredient_name for ingredient in recipe.ingredients),
    )

    cuisine_signals = (
        (("bbq", "barbecue", "smoked", "burnt ends", "brisket"), "barbecue"),
        (("italian", "pasta", "parmesan", "gremolata"), "italian"),
        (("mexican", "taco", "enchilada", "cilantro lime", "avocado crema"), "mexican"),
        (("thai", "peanut", "fish sauce", "jasmine rice", "curry"), "thai"),
        (("middle eastern", "shawarma", "tahini", "sumac", "zaatar", "za atar"), "middle_eastern"),
    )
    for keywords, key in cuisine_signals:
        if any(keyword in signal_text for keyword in keywords):
            return key
    return "neutral"


def _companion_recipe_payload(
    anchor_recipe: RecipePayload,
    preset: CompanionPreset,
) -> RecipePayload:
    combined_notes = f"{preset.notes}\n\nWhy this fits: {preset.rationale}\nAnchor recipe: {anchor_recipe.name}"
    return RecipePayload(
        recipe_id=None,
        recipe_template_id=anchor_recipe.recipe_template_id,
        base_recipe_id=None,
        name=preset.name,
        meal_type=anchor_recipe.meal_type or preset.meal_type,
        cuisine=anchor_recipe.cuisine or preset.cuisine,
        servings=anchor_recipe.servings or 4,
        prep_minutes=10,
        cook_minutes=15,
        tags=list(dict.fromkeys(preset.tags)),
        instructions_summary=preset.rationale,
        favorite=False,
        source="ai_companion",
        source_label=f"Companion for {anchor_recipe.name}",
        source_url="",
        notes=combined_notes,
        memories="",
        last_used=None,
        ingredients=[ingredient.model_copy(deep=True) for ingredient in preset.ingredients],
        steps=[step.model_copy(deep=True) for step in preset.steps],
        nutrition_summary=None,
    )


def build_suggestion_draft(
    saved_recipes: list[RecipePayload],
    *,
    goal: str,
) -> tuple[RecipePayload, str, str]:
    if not saved_recipes:
        raise ValueError("Save a few recipes before requesting an AI suggestion draft.")

    preset = resolve_suggestion_preset(goal)
    matching_recipes = [recipe for recipe in saved_recipes if _meal_type_matches(recipe, preset.meal_type)]
    fallback_used = not matching_recipes
    candidates = matching_recipes or saved_recipes
    anchor = sorted(candidates, key=lambda recipe: _recipe_score(recipe, preset), reverse=True)[0]

    variation_rationale = ""
    if preset.variation_goal:
        draft, variation_rationale, _ = build_variation_draft(anchor, goal=preset.variation_goal)
    else:
        draft = anchor.model_copy(deep=True)

    suggestion_note = preset.rationale_note
    if fallback_used:
        suggestion_note += f" No strong {preset.meal_type} match exists yet, so this starts from your closest saved recipe."
    if anchor.source_label:
        suggestion_note += f" Source signal: {anchor.source_label}."
    if variation_rationale:
        suggestion_note += f" {variation_rationale}"

    existing_notes = draft.notes.strip()
    combined_notes = (
        f"{existing_notes}\n\nAI suggestion note: {suggestion_note}".strip()
        if existing_notes
        else f"AI suggestion note: {suggestion_note}"
    )

    deduped_tags = list(dict.fromkeys([*draft.tags, *preset.extra_tags]))
    final_draft = draft.model_copy(
        update={
            "recipe_id": None,
            "base_recipe_id": anchor.base_recipe_id or anchor.recipe_id,
            "name": _prefixed_title(preset.title_prefix, anchor.name),
            "meal_type": preset.meal_type or draft.meal_type,
            "favorite": False,
            "source": "ai_suggestion",
            "source_label": anchor.source_label,
            "source_url": anchor.source_url,
            "notes": combined_notes,
            "last_used": None,
            "tags": deduped_tags,
        }
    )

    rationale = preset.rationale_note
    rationale += f" Started from {anchor.name}"
    if anchor.cuisine:
        rationale += f" with a {anchor.cuisine} lean"
    rationale += "."
    if fallback_used:
        rationale += f" No strong {preset.meal_type} match existed yet, so this used the closest saved recipe."
    return final_draft, rationale, preset.label


def build_companion_drafts(
    anchor_recipe: RecipePayload,
    *,
    focus: str = "sides_and_sauces",
) -> tuple[list[tuple[str, str, str, RecipePayload]], str, str]:
    if focus != "sides_and_sauces":
        raise ValueError("Unsupported companion focus.")

    library_key = _infer_companion_library_key(anchor_recipe)
    presets = COMPANION_LIBRARY.get(library_key, COMPANION_LIBRARY["neutral"])
    drafts: list[tuple[str, str, str, RecipePayload]] = []
    for preset in presets:
        drafts.append(
            (
                preset.option_id,
                preset.label,
                preset.rationale,
                _companion_recipe_payload(anchor_recipe, preset),
            )
        )

    rationale = (
        f"Three companion drafts were built from {anchor_recipe.name} using a {library_key.replace('_', ' ')} flavor profile."
        if library_key != "neutral"
        else f"Three companion drafts were built from {anchor_recipe.name} using neutral sides-and-sauces defaults."
    )
    return drafts, rationale, "Sides and Sauces"
