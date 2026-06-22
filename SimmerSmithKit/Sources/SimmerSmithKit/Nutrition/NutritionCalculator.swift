import Foundation

// SP-C AI-3 — Deterministic nutrition port (NOT LLM).
//
// Swift port of the server's `app/services/nutrition.py::calculate_recipe_nutrition`
// (+ `_calories_for_reference` / `_macros_for_reference` unit conversion). The macro
// data lives in the catalog (BaseIngredient / IngredientVariation:
// nutrition_reference_amount/unit, calories, protein_g/carbs_g/fat_g/fiber_g). The
// catalog lookup is INJECTED as a closure so this type is pure + headless-testable:
// the app wires in a closure backed by PublicCatalogReader (PUBLIC catalog) +
// the per-household ingredient→nutrition match.
//
// CATALOG-MACRO REALITY (verified 2026-06-22): the iOS public-catalog read currently
// projects calories only — the domain `BaseIngredient` decodes
// `nutritionReferenceAmount/nutritionReferenceUnit/calories` and the iOS
// `NutritionSummary` is calorie-level (no per-serving macro field). The PUBLIC
// CKRecords are a frozen one-time seed (no curator publish path in-repo yet), so
// full macros (protein/carbs/fat/fiber) are NOT yet guaranteed on the published
// records. This calculator therefore produces a calorie-level `NutritionSummary`
// (matching the domain type), but `CatalogMacros` carries the full macro tuple +
// `MacroBreakdown` aggregation so the math is forward-compatible the moment the
// catalog publishes the macro columns — no rewrite needed.

/// A per-reference macro row pulled from the catalog for one ingredient. Mirrors the
/// server's per-ingredient nutrition fields: a reference amount/unit (e.g. 100 g) and
/// the macros at that reference. Any macro may be nil (the seed often has calories only).
public struct CatalogMacros: Sendable, Equatable {
    /// The amount the macros are stated per (e.g. 100 for "per 100 g"). nil/≤0 → not computable.
    public let referenceAmount: Double?
    /// The unit the reference amount is in (e.g. "g"). Compared against the recipe unit.
    public let referenceUnit: String
    public let calories: Double?
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    public let fiberG: Double?

    public init(
        referenceAmount: Double?,
        referenceUnit: String,
        calories: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        fiberG: Double? = nil
    ) {
        self.referenceAmount = referenceAmount
        self.referenceUnit = referenceUnit
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
    }
}

/// Absolute or per-serving nutrition totals. Port of the server `MacroBreakdown`
/// dataclass (`scaled` / `+` / `is_empty`).
public struct ScaledMacros: Sendable, Equatable {
    public var calories: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double

    public init(
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fiberG: Double = 0
    ) {
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
    }

    public func scaled(by factor: Double) -> ScaledMacros {
        ScaledMacros(
            calories: calories * factor,
            proteinG: proteinG * factor,
            carbsG: carbsG * factor,
            fatG: fatG * factor,
            fiberG: fiberG * factor
        )
    }

    public static func + (lhs: ScaledMacros, rhs: ScaledMacros) -> ScaledMacros {
        ScaledMacros(
            calories: lhs.calories + rhs.calories,
            proteinG: lhs.proteinG + rhs.proteinG,
            carbsG: lhs.carbsG + rhs.carbsG,
            fatG: lhs.fatG + rhs.fatG,
            fiberG: lhs.fiberG + rhs.fiberG
        )
    }

    public var isEmpty: Bool {
        calories == 0 && proteinG == 0 && carbsG == 0 && fatG == 0 && fiberG == 0
    }
}

/// Pure, headless nutrition calculator. Port of `calculate_recipe_nutrition`.
public struct NutritionCalculator: Sendable {
    /// The identifiers the catalog lookup may key off, per recipe ingredient. Mirrors the
    /// server's `_lookup_catalog_*`: prefer a variation, then the base ingredient, then a
    /// name/normalized-name match against the nutrition-item table. The injected closure
    /// decides which source it can satisfy.
    public struct IngredientKey: Sendable, Equatable {
        public let ingredientName: String
        public let normalizedName: String?
        public let baseIngredientID: String?
        public let ingredientVariationID: String?

        public init(
            ingredientName: String,
            normalizedName: String? = nil,
            baseIngredientID: String? = nil,
            ingredientVariationID: String? = nil
        ) {
            self.ingredientName = ingredientName
            self.normalizedName = normalizedName
            self.baseIngredientID = baseIngredientID
            self.ingredientVariationID = ingredientVariationID
        }
    }

    /// One recipe ingredient line, as the calculator consumes it.
    public struct Ingredient: Sendable, Equatable {
        public let key: IngredientKey
        public let quantity: Double?
        public let unit: String

        public init(key: IngredientKey, quantity: Double?, unit: String) {
            self.key = key
            self.quantity = quantity
            self.unit = unit
        }
    }

    /// Catalog lookup: given an ingredient key, return its per-reference macros (or nil
    /// if the catalog can't resolve it). Injected so production wires PublicCatalogReader
    /// + the household match, and tests inject a fixture.
    public typealias CatalogLookup = @Sendable (IngredientKey) -> CatalogMacros?

    private let lookup: CatalogLookup
    private let now: @Sendable () -> Date

    public init(lookup: @escaping CatalogLookup, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lookup = lookup
        self.now = now
    }

    // MARK: - Public API

    /// Port of `calculate_recipe_nutrition`: per-ingredient catalog lookup + unit-converted
    /// scaling + aggregation → a calorie-level `NutritionSummary` (total + per-serving +
    /// coverage + unmatched). Coverage:
    /// - `unavailable` when nothing matched,
    /// - `complete` when everything matched,
    /// - `partial` when some ingredients matched and others did not.
    public func calculateRecipeNutrition(
        ingredients: [Ingredient],
        servings: Double?
    ) -> NutritionSummary {
        var totalCalories = 0.0
        var matched = 0
        var unmatchedNames: [String] = []
        var seenUnmatched = Set<String>()

        for ingredient in ingredients {
            let calories = caloriesForIngredient(ingredient)
            if let calories {
                totalCalories += calories
                matched += 1
            } else {
                let name = ingredient.key.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = ingredient.key.normalizedName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? Self.normalizeName(name)
                if !name.isEmpty, !seenUnmatched.contains(key) {
                    seenUnmatched.insert(key)
                    unmatchedNames.append(name)
                }
            }
        }

        let unmatchedCount = unmatchedNames.count
        let coverageStatus: String
        if matched == 0 {
            coverageStatus = "unavailable"
        } else if unmatchedCount == 0 {
            coverageStatus = "complete"
        } else {
            coverageStatus = "partial"
        }

        var caloriesPerServing: Double? = nil
        if let servings, servings > 0, matched > 0 {
            caloriesPerServing = Self.round1(totalCalories / servings)
        }

        return NutritionSummary(
            totalCalories: matched > 0 ? Self.round1(totalCalories) : nil,
            caloriesPerServing: caloriesPerServing,
            coverageStatus: coverageStatus,
            matchedIngredientCount: matched,
            unmatchedIngredientCount: unmatchedCount,
            unmatchedIngredients: unmatchedNames,
            lastCalculatedAt: now()
        )
    }

    /// Port of `_macros_for_reference` applied across a meal's ingredients (server
    /// `calculate_meal_macros`). Unresolved ingredients contribute zero; the caller decides
    /// whether the total is trustworthy. Forward-compatible with full catalog macros.
    public func calculateMealMacros(ingredients: [Ingredient]) -> ScaledMacros {
        var total = ScaledMacros()
        for ingredient in ingredients {
            guard let catalog = lookup(ingredient.key) else { continue }
            if let macros = Self.macrosForReference(
                quantity: ingredient.quantity,
                unit: ingredient.unit,
                catalog: catalog
            ) {
                total = total + macros
            }
        }
        return total
    }

    // MARK: - Per-ingredient calorie lookup (port of `_lookup_catalog_calories` chain)

    private func caloriesForIngredient(_ ingredient: Ingredient) -> Double? {
        guard let catalog = lookup(ingredient.key) else { return nil }
        return Self.caloriesForReference(
            quantity: ingredient.quantity,
            unit: ingredient.unit,
            referenceAmount: catalog.referenceAmount,
            referenceUnit: catalog.referenceUnit,
            calories: catalog.calories
        )
    }

    // MARK: - Unit conversion (port of `_calories_for_reference` / `_macros_for_reference`)

    /// Mass units → grams. Mirrors the server `MASS_UNIT_GRAMS`.
    static let massUnitGrams: [String: Double] = [
        "g": 1.0, "gram": 1.0, "grams": 1.0,
        "oz": 28.3495, "ounce": 28.3495, "ounces": 28.3495,
        "lb": 453.592, "lbs": 453.592, "pound": 453.592, "pounds": 453.592,
    ]

    /// Volume units → millilitres. Mirrors the server `VOLUME_UNIT_ML`.
    static let volumeUnitMl: [String: Double] = [
        "ml": 1.0, "milliliter": 1.0, "milliliters": 1.0,
        "tsp": 4.92892, "teaspoon": 4.92892, "teaspoons": 4.92892,
        "tbsp": 14.7868, "tablespoon": 14.7868, "tablespoons": 14.7868,
        "fl oz": 29.5735, "fluid ounce": 29.5735, "fluid ounces": 29.5735,
        "cup": 236.588, "cups": 236.588,
        "gal": 3785.41, "gallon": 3785.41, "gallons": 3785.41,
    ]

    enum UnitDimension: Equatable { case mass, volume }

    /// Port of `_unit_group`: the (dimension, factor-to-base) for a normalized unit, or nil.
    static func unitGroup(_ unit: String) -> (UnitDimension, Double)? {
        let normalized = normalizeName(unit)
        if let factor = massUnitGrams[normalized] { return (.mass, factor) }
        if let factor = volumeUnitMl[normalized] { return (.volume, factor) }
        return nil
    }

    /// Port of `_calories_for_reference`: scale `calories` from the reference amount/unit to
    /// the recipe's `(quantity, unit)`. Same-unit → direct ratio; cross-unit → only when both
    /// units share a dimension (mass↔mass, volume↔volume). Returns nil when not computable.
    static func caloriesForReference(
        quantity: Double?,
        unit: String,
        referenceAmount: Double?,
        referenceUnit: String,
        calories: Double?
    ) -> Double? {
        guard let calories else { return nil }
        guard let quantity, quantity > 0 else { return nil }
        guard let referenceAmount, referenceAmount > 0 else { return nil }

        let recipeUnit = normalizeName(unit)
        let normalizedReferenceUnit = normalizeName(referenceUnit)
        if recipeUnit == normalizedReferenceUnit {
            let factor = quantity / referenceAmount
            return round2(calories * factor)
        }

        guard
            let recipeGroup = unitGroup(recipeUnit),
            let referenceGroup = unitGroup(normalizedReferenceUnit),
            recipeGroup.0 == referenceGroup.0
        else { return nil }

        let baseQuantity = quantity * recipeGroup.1
        let referenceQuantity = referenceAmount * referenceGroup.1
        guard referenceQuantity > 0 else { return nil }
        let factor = baseQuantity / referenceQuantity
        return round2(calories * factor)
    }

    /// Port of `_macros_for_reference`: same scaling factor as calories, applied to the full
    /// macro tuple. nil when no macro is present or the units can't convert.
    static func macrosForReference(
        quantity: Double?,
        unit: String,
        catalog: CatalogMacros
    ) -> ScaledMacros? {
        guard let referenceAmount = catalog.referenceAmount, referenceAmount > 0 else { return nil }
        guard let quantity, quantity > 0 else { return nil }
        if catalog.calories == nil
            && catalog.proteinG == nil
            && catalog.carbsG == nil
            && catalog.fatG == nil
            && catalog.fiberG == nil {
            return nil
        }

        let factor: Double
        let recipeUnit = normalizeName(unit)
        let normalizedReferenceUnit = normalizeName(catalog.referenceUnit)
        if recipeUnit == normalizedReferenceUnit {
            factor = quantity / referenceAmount
        } else {
            guard
                let recipeGroup = unitGroup(recipeUnit),
                let referenceGroup = unitGroup(normalizedReferenceUnit),
                recipeGroup.0 == referenceGroup.0
            else { return nil }
            let baseQuantity = quantity * recipeGroup.1
            let referenceQuantity = referenceAmount * referenceGroup.1
            guard referenceQuantity > 0 else { return nil }
            factor = baseQuantity / referenceQuantity
        }

        return ScaledMacros(
            calories: (catalog.calories ?? 0) * factor,
            proteinG: (catalog.proteinG ?? 0) * factor,
            carbsG: (catalog.carbsG ?? 0) * factor,
            fatG: (catalog.fatG ?? 0) * factor,
            fiberG: (catalog.fiberG ?? 0) * factor
        )
    }

    // MARK: - Name normalization (port of `app/services/grocery.py::normalize_name`)

    /// Port of the server `normalize_name`: lowercased, `&`→` and `, non-alphanumerics→space,
    /// whitespace collapsed + trimmed. Used both for unit normalization and unmatched-name dedupe.
    public static func normalizeName(_ value: String) -> String {
        var cleaned = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "&", with: " and ")
        let scalars = cleaned.unicodeScalars.map { scalar -> Character in
            let isLower = scalar >= "a" && scalar <= "z"
            let isDigit = scalar >= "0" && scalar <= "9"
            let isSpace = scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
            return (isLower || isDigit || isSpace) ? Character(scalar) : " "
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
        return collapsed
    }

    // MARK: - Rounding (mirror Python `round(x, n)` banker's-free half-up-ish for our magnitudes)

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
