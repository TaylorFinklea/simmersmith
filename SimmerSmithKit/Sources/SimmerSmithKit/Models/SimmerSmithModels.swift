import Foundation

/// A small type that can round-trip arbitrary JSON values — used for
/// assistant tool-call arguments where the shape varies per tool.
public enum SimmerSmithJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([SimmerSmithJSONValue])
    case object([String: SimmerSmithJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let int = try? container.decode(Int.self) {
            self = .integer(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .number(double)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let array = try? container.decode([SimmerSmithJSONValue].self) {
            self = .array(array)
            return
        }
        if let object = try? container.decode([String: SimmerSmithJSONValue].self) {
            self = .object(object)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringDescription: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .integer(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return "null"
        case .array(let value):
            return "[" + value.map { $0.stringDescription }.joined(separator: ", ") + "]"
        case .object(let value):
            return "{" + value.map { "\($0.key): \($0.value.stringDescription)" }.joined(separator: ", ") + "}"
        }
    }
}

public struct AuthTokenResponse: Codable, Sendable {
    public let token: String
    public let userId: String
    public let email: String
    public let displayName: String
    public let isNewUser: Bool
}

public struct HealthResponse: Codable, Sendable {
    public let status: String
    public let aiCapabilities: AICapabilities?

    enum CodingKeys: String, CodingKey {
        case status
        case aiCapabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        aiCapabilities = try container.decodeIfPresent(AICapabilities.self, forKey: .aiCapabilities)
    }
}

public struct Staple: Codable, Identifiable, Hashable, Sendable {
    public let stapleName: String
    public let normalizedName: String
    public let notes: String
    public let isActive: Bool

    public var id: String { normalizedName }
}

public struct UsageSummary: Codable, Sendable, Hashable {
    public let action: String
    public let limit: Int
    public let used: Int
    public let remaining: Int
}

public struct ProfileSnapshot: Codable, Sendable {
    public let updatedAt: Date?
    public let settings: [String: String]
    public let secretFlags: [String: Bool]
    public let staples: [Staple]
    public let dietaryGoal: DietaryGoal?
    public let isPro: Bool
    public let isTrial: Bool
    public let usage: [UsageSummary]

    enum CodingKeys: String, CodingKey {
        case updatedAt
        case settings
        case secretFlags
        case staples
        case dietaryGoal
        case isPro
        case isTrial
        case usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        settings = try container.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
        secretFlags = try container.decodeIfPresent([String: Bool].self, forKey: .secretFlags) ?? [:]
        staples = try container.decodeIfPresent([Staple].self, forKey: .staples) ?? []
        dietaryGoal = try container.decodeIfPresent(DietaryGoal.self, forKey: .dietaryGoal)
        isPro = try container.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
        isTrial = try container.decodeIfPresent(Bool.self, forKey: .isTrial) ?? false
        usage = try container.decodeIfPresent([UsageSummary].self, forKey: .usage) ?? []
    }
}

public struct SubscriptionStatus: Codable, Sendable {
    public let status: String
    public let productId: String
    public let currentPeriodEndsAt: Date?
    public let autoRenew: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case productId
        case currentPeriodEndsAt
        case autoRenew
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        productId = try container.decode(String.self, forKey: .productId)
        autoRenew = try container.decodeIfPresent(Bool.self, forKey: .autoRenew) ?? false

        // Backend emits ISO-8601 with the full datetime + offset (via
        // `.isoformat()`). Use the default decoder when available; fall
        // back to a permissive ISO-8601 parse for the offset-aware form.
        if let raw = try? container.decode(Date.self, forKey: .currentPeriodEndsAt) {
            currentPeriodEndsAt = raw
        } else if let string = try? container.decode(String.self, forKey: .currentPeriodEndsAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
            currentPeriodEndsAt = formatter.date(from: string)
                ?? ISO8601DateFormatter().date(from: string)
        } else {
            currentPeriodEndsAt = nil
        }
    }
}

public enum DietaryGoalType: String, Codable, Sendable, CaseIterable {
    case lose
    case maintain
    case gain
    case custom
}

public struct DietaryGoal: Codable, Sendable, Hashable {
    public var goalType: DietaryGoalType
    public var dailyCalories: Int
    public var proteinG: Int
    public var carbsG: Int
    public var fatG: Int
    public var fiberG: Int?
    public var notes: String
    public var updatedAt: Date?

    public init(
        goalType: DietaryGoalType = .maintain,
        dailyCalories: Int,
        proteinG: Int,
        carbsG: Int,
        fatG: Int,
        fiberG: Int? = nil,
        notes: String = "",
        updatedAt: Date? = nil
    ) {
        self.goalType = goalType
        self.dailyCalories = dailyCalories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

public struct MacroBreakdown: Codable, Sendable, Hashable {
    public let calories: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double
    public let fiberG: Double

    public init(calories: Double = 0, proteinG: Double = 0, carbsG: Double = 0, fatG: Double = 0, fiberG: Double = 0) {
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
    }
}

public struct DailyNutrition: Codable, Sendable, Hashable {
    public let mealDate: Date
    public let calories: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double
    public let fiberG: Double

    public var macros: MacroBreakdown {
        MacroBreakdown(calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG, fiberG: fiberG)
    }
}

public struct AIProviderTarget: Codable, Hashable, Sendable {
    public let providerKind: String
    public let mode: String
    public let source: String
    public let providerName: String?
    public let mcpServerName: String?
}

public struct AIProviderAvailability: Codable, Identifiable, Hashable, Sendable {
    public let providerId: String
    public let label: String
    public let providerKind: String
    public let available: Bool
    public let source: String

    public var id: String { providerId }
}

public struct AICapabilities: Codable, Hashable, Sendable {
    public let supportsUserOverride: Bool
    public let preferredMode: String
    public let userOverrideProvider: String?
    public let userOverrideConfigured: Bool
    public let defaultTarget: AIProviderTarget?
    public let availableProviders: [AIProviderAvailability]
}

public struct AIModelOption: Codable, Identifiable, Hashable, Sendable {
    public let providerId: String
    public let modelId: String
    public let displayName: String

    public var id: String { modelId }
}

public struct AIProviderModels: Codable, Hashable, Sendable {
    public let providerId: String
    public let selectedModelId: String?
    public let models: [AIModelOption]
    public let source: String
}

public struct ManagedListItem: Codable, Identifiable, Hashable, Sendable {
    public let itemId: String
    public let kind: String
    public let name: String
    public let normalizedName: String
    public let updatedAt: Date

    public var id: String { itemId }
}

public struct RecipeMetadata: Codable, Hashable, Sendable {
    public let updatedAt: Date?
    public let cuisines: [ManagedListItem]
    public let tags: [ManagedListItem]
    public let units: [ManagedListItem]
    public let defaultTemplateId: String?
    public let templates: [RecipeTemplate]

    enum CodingKeys: String, CodingKey {
        case updatedAt
        case cuisines
        case tags
        case units
        case defaultTemplateId
        case templates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        cuisines = try container.decodeIfPresent([ManagedListItem].self, forKey: .cuisines) ?? []
        tags = try container.decodeIfPresent([ManagedListItem].self, forKey: .tags) ?? []
        units = try container.decodeIfPresent([ManagedListItem].self, forKey: .units) ?? []
        defaultTemplateId = try container.decodeIfPresent(String.self, forKey: .defaultTemplateId)
        templates = try container.decodeIfPresent([RecipeTemplate].self, forKey: .templates) ?? []
    }
}

public struct RecipeTemplate: Codable, Identifiable, Hashable, Sendable {
    public let templateId: String
    public let slug: String
    public let name: String
    public let description: String
    public let sectionOrder: [String]
    public let shareSource: Bool
    public let shareMemories: Bool
    public let builtIn: Bool
    public let updatedAt: Date

    public var id: String { templateId }
}

public struct NutritionSummary: Codable, Hashable, Sendable {
    public let totalCalories: Double?
    public let caloriesPerServing: Double?
    public let coverageStatus: String
    public let matchedIngredientCount: Int
    public let unmatchedIngredientCount: Int
    public let unmatchedIngredients: [String]
    public let lastCalculatedAt: Date?
}

public struct NutritionItem: Codable, Identifiable, Hashable, Sendable {
    public let itemId: String
    public let name: String
    public let normalizedName: String
    public let referenceAmount: Double
    public let referenceUnit: String
    public let calories: Double
    public let notes: String

    public var id: String { itemId }
}

public struct IngredientNutritionMatch: Codable, Hashable, Sendable {
    public let matchId: String
    public let ingredientName: String
    public let normalizedName: String
    public let nutritionItem: NutritionItem
    public let updatedAt: Date
}

public struct BaseIngredient: Codable, Identifiable, Hashable, Sendable {
    public let baseIngredientId: String
    public let name: String
    public let normalizedName: String
    public let category: String
    public let defaultUnit: String
    public let notes: String
    public let sourceName: String
    public let sourceRecordId: String
    public let sourceURL: String
    public let provisional: Bool
    public let active: Bool
    public let nutritionReferenceAmount: Double?
    public let nutritionReferenceUnit: String
    public let calories: Double?
    public let archivedAt: Date?
    public let mergedIntoId: String?
    public let variationCount: Int
    public let preferenceCount: Int
    public let recipeUsageCount: Int
    public let groceryUsageCount: Int
    public let productLike: Bool
    public let updatedAt: Date

    public var id: String { baseIngredientId }

    public init(
        baseIngredientId: String,
        name: String,
        normalizedName: String,
        category: String = "",
        defaultUnit: String = "",
        notes: String = "",
        sourceName: String = "",
        sourceRecordId: String = "",
        sourceURL: String = "",
        provisional: Bool = false,
        active: Bool = true,
        nutritionReferenceAmount: Double? = nil,
        nutritionReferenceUnit: String = "",
        calories: Double? = nil,
        archivedAt: Date? = nil,
        mergedIntoId: String? = nil,
        variationCount: Int = 0,
        preferenceCount: Int = 0,
        recipeUsageCount: Int = 0,
        groceryUsageCount: Int = 0,
        productLike: Bool = false,
        updatedAt: Date
    ) {
        self.baseIngredientId = baseIngredientId
        self.name = name
        self.normalizedName = normalizedName
        self.category = category
        self.defaultUnit = defaultUnit
        self.notes = notes
        self.sourceName = sourceName
        self.sourceRecordId = sourceRecordId
        self.sourceURL = sourceURL
        self.provisional = provisional
        self.active = active
        self.nutritionReferenceAmount = nutritionReferenceAmount
        self.nutritionReferenceUnit = nutritionReferenceUnit
        self.calories = calories
        self.archivedAt = archivedAt
        self.mergedIntoId = mergedIntoId
        self.variationCount = variationCount
        self.preferenceCount = preferenceCount
        self.recipeUsageCount = recipeUsageCount
        self.groceryUsageCount = groceryUsageCount
        self.productLike = productLike
        self.updatedAt = updatedAt
    }
}

public struct IngredientVariation: Codable, Identifiable, Hashable, Sendable {
    public let ingredientVariationId: String
    public let baseIngredientId: String
    public let name: String
    public let normalizedName: String
    public let brand: String
    public let upc: String
    public let packageSizeAmount: Double?
    public let packageSizeUnit: String
    public let countPerPackage: Double?
    public let productUrl: String
    public let retailerHint: String
    public let notes: String
    public let sourceName: String
    public let sourceRecordId: String
    public let sourceURL: String
    public let active: Bool
    public let nutritionReferenceAmount: Double?
    public let nutritionReferenceUnit: String
    public let calories: Double?
    public let archivedAt: Date?
    public let mergedIntoId: String?
    public let updatedAt: Date

    public var id: String { ingredientVariationId }

    public init(
        ingredientVariationId: String,
        baseIngredientId: String,
        name: String,
        normalizedName: String,
        brand: String = "",
        upc: String = "",
        packageSizeAmount: Double? = nil,
        packageSizeUnit: String = "",
        countPerPackage: Double? = nil,
        productUrl: String = "",
        retailerHint: String = "",
        notes: String = "",
        sourceName: String = "",
        sourceRecordId: String = "",
        sourceURL: String = "",
        active: Bool = true,
        nutritionReferenceAmount: Double? = nil,
        nutritionReferenceUnit: String = "",
        calories: Double? = nil,
        archivedAt: Date? = nil,
        mergedIntoId: String? = nil,
        updatedAt: Date
    ) {
        self.ingredientVariationId = ingredientVariationId
        self.baseIngredientId = baseIngredientId
        self.name = name
        self.normalizedName = normalizedName
        self.brand = brand
        self.upc = upc
        self.packageSizeAmount = packageSizeAmount
        self.packageSizeUnit = packageSizeUnit
        self.countPerPackage = countPerPackage
        self.productUrl = productUrl
        self.retailerHint = retailerHint
        self.notes = notes
        self.sourceName = sourceName
        self.sourceRecordId = sourceRecordId
        self.sourceURL = sourceURL
        self.active = active
        self.nutritionReferenceAmount = nutritionReferenceAmount
        self.nutritionReferenceUnit = nutritionReferenceUnit
        self.calories = calories
        self.archivedAt = archivedAt
        self.mergedIntoId = mergedIntoId
        self.updatedAt = updatedAt
    }
}

public struct IngredientUsageSummary: Codable, Hashable, Sendable {
    public let linkedRecipeIds: [String]
    public let linkedRecipeNames: [String]
    public let linkedGroceryItemIds: [String]
    public let linkedGroceryNames: [String]
}

public struct BaseIngredientDetail: Codable, Hashable, Sendable {
    public let ingredient: BaseIngredient
    public let variations: [IngredientVariation]
    public let preference: IngredientPreference?
    public let usage: IngredientUsageSummary
}

public struct IngredientResolution: Codable, Hashable, Sendable {
    public let ingredientName: String
    public let normalizedName: String
    public let quantity: Double?
    public let unit: String
    public let prep: String
    public let category: String
    public let notes: String
    public let baseIngredientId: String?
    public let baseIngredientName: String?
    public let ingredientVariationId: String?
    public let ingredientVariationName: String?
    public let resolutionStatus: String
}

public struct IngredientPreference: Codable, Identifiable, Hashable, Sendable {
    public let preferenceId: String
    public let baseIngredientId: String
    public let baseIngredientName: String
    public let preferredVariationId: String?
    public let preferredVariationName: String?
    public let preferredBrand: String
    public let choiceMode: String
    public let active: Bool
    public let notes: String
    public let updatedAt: Date

    public var id: String { preferenceId }
}

public struct RecipeIngredient: Codable, Identifiable, Hashable, Sendable {
    public var ingredientId: String?
    public var ingredientName: String
    public var normalizedName: String?
    public var baseIngredientId: String?
    public var baseIngredientName: String?
    public var ingredientVariationId: String?
    public var ingredientVariationName: String?
    public var resolutionStatus: String
    public var quantity: Double?
    public var unit: String
    public var prep: String
    public var category: String
    public var notes: String

    public var id: String {
        ingredientId ?? normalizedName ?? ingredientName
    }

    public init(
        ingredientId: String? = nil,
        ingredientName: String,
        normalizedName: String? = nil,
        baseIngredientId: String? = nil,
        baseIngredientName: String? = nil,
        ingredientVariationId: String? = nil,
        ingredientVariationName: String? = nil,
        resolutionStatus: String = "unresolved",
        quantity: Double? = nil,
        unit: String = "",
        prep: String = "",
        category: String = "",
        notes: String = ""
    ) {
        self.ingredientId = ingredientId
        self.ingredientName = ingredientName
        self.normalizedName = normalizedName
        self.baseIngredientId = baseIngredientId
        self.baseIngredientName = baseIngredientName
        self.ingredientVariationId = ingredientVariationId
        self.ingredientVariationName = ingredientVariationName
        self.resolutionStatus = resolutionStatus
        self.quantity = quantity
        self.unit = unit
        self.prep = prep
        self.category = category
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case ingredientId
        case ingredientName
        case normalizedName
        case baseIngredientId
        case baseIngredientName
        case ingredientVariationId
        case ingredientVariationName
        case resolutionStatus
        case quantity
        case unit
        case prep
        case category
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ingredientId = try container.decodeIfPresent(String.self, forKey: .ingredientId)
        ingredientName = try container.decode(String.self, forKey: .ingredientName)
        normalizedName = try container.decodeIfPresent(String.self, forKey: .normalizedName)
        baseIngredientId = try container.decodeIfPresent(String.self, forKey: .baseIngredientId)
        baseIngredientName = try container.decodeIfPresent(String.self, forKey: .baseIngredientName)
        ingredientVariationId = try container.decodeIfPresent(String.self, forKey: .ingredientVariationId)
        ingredientVariationName = try container.decodeIfPresent(String.self, forKey: .ingredientVariationName)
        resolutionStatus = try container.decodeIfPresent(String.self, forKey: .resolutionStatus) ?? "unresolved"
        quantity = try container.decodeIfPresent(Double.self, forKey: .quantity)
        unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        prep = try container.decodeIfPresent(String.self, forKey: .prep) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

public struct RecipeStep: Codable, Identifiable, Hashable, Sendable {
    public var stepId: String?
    public var sortOrder: Int
    public var instruction: String
    public var substeps: [RecipeStep] = []

    public var id: String {
        stepId ?? "\(sortOrder)-\(instruction)"
    }

    public init(
        stepId: String? = nil,
        sortOrder: Int,
        instruction: String,
        substeps: [RecipeStep] = []
    ) {
        self.stepId = stepId
        self.sortOrder = sortOrder
        self.instruction = instruction
        self.substeps = substeps
    }

    enum CodingKeys: String, CodingKey {
        case stepId
        case sortOrder
        case instruction
        case substeps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stepId = try container.decodeIfPresent(String.self, forKey: .stepId)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        instruction = try container.decode(String.self, forKey: .instruction)
        substeps = try container.decodeIfPresent([RecipeStep].self, forKey: .substeps) ?? []
    }
}

public struct RecipeDraft: Codable, Hashable, Sendable {
    public var recipeId: String?
    public var recipeTemplateId: String?
    public var baseRecipeId: String?
    public var name: String
    public var mealType: String
    public var cuisine: String
    public var servings: Double?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var tags: [String]
    public var instructionsSummary: String
    public var favorite: Bool
    public var source: String
    public var sourceLabel: String
    public var sourceUrl: String
    public var notes: String
    public var memories: String
    public var lastUsed: Date?
    public var ingredients: [RecipeIngredient]
    public var steps: [RecipeStep]
    public var nutritionSummary: NutritionSummary?

    public init(
        recipeId: String? = nil,
        recipeTemplateId: String? = nil,
        baseRecipeId: String? = nil,
        name: String,
        mealType: String = "",
        cuisine: String = "",
        servings: Double? = nil,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        tags: [String] = [],
        instructionsSummary: String = "",
        favorite: Bool = false,
        source: String = "manual",
        sourceLabel: String = "",
        sourceUrl: String = "",
        notes: String = "",
        memories: String = "",
        lastUsed: Date? = nil,
        ingredients: [RecipeIngredient] = [],
        steps: [RecipeStep] = [],
        nutritionSummary: NutritionSummary? = nil
    ) {
        self.recipeId = recipeId
        self.recipeTemplateId = recipeTemplateId
        self.baseRecipeId = baseRecipeId
        self.name = name
        self.mealType = mealType
        self.cuisine = cuisine
        self.servings = servings
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.tags = tags
        self.instructionsSummary = instructionsSummary
        self.favorite = favorite
        self.source = source
        self.sourceLabel = sourceLabel
        self.sourceUrl = sourceUrl
        self.notes = notes
        self.memories = memories
        self.lastUsed = lastUsed
        self.ingredients = ingredients
        self.steps = steps
        self.nutritionSummary = nutritionSummary
    }

    enum CodingKeys: String, CodingKey {
        case recipeId
        case recipeTemplateId
        case baseRecipeId
        case name
        case mealType
        case cuisine
        case servings
        case prepMinutes
        case cookMinutes
        case tags
        case instructionsSummary
        case favorite
        case source
        case sourceLabel
        case sourceUrl
        case notes
        case memories
        case lastUsed
        case ingredients
        case steps
        case nutritionSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipeId = try container.decodeIfPresent(String.self, forKey: .recipeId)
        recipeTemplateId = try container.decodeIfPresent(String.self, forKey: .recipeTemplateId)
        baseRecipeId = try container.decodeIfPresent(String.self, forKey: .baseRecipeId)
        name = try container.decode(String.self, forKey: .name)
        mealType = try container.decodeIfPresent(String.self, forKey: .mealType) ?? ""
        cuisine = try container.decodeIfPresent(String.self, forKey: .cuisine) ?? ""
        servings = try container.decodeIfPresent(Double.self, forKey: .servings)
        prepMinutes = try container.decodeIfPresent(Int.self, forKey: .prepMinutes)
        cookMinutes = try container.decodeIfPresent(Int.self, forKey: .cookMinutes)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        instructionsSummary = try container.decodeIfPresent(String.self, forKey: .instructionsSummary) ?? ""
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        sourceUrl = try container.decodeIfPresent(String.self, forKey: .sourceUrl) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        memories = try container.decodeIfPresent(String.self, forKey: .memories) ?? ""
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        ingredients = try container.decodeIfPresent([RecipeIngredient].self, forKey: .ingredients) ?? []
        steps = try container.decodeIfPresent([RecipeStep].self, forKey: .steps) ?? []
        nutritionSummary = try container.decodeIfPresent(NutritionSummary.self, forKey: .nutritionSummary)
    }
}

public struct RecipeAIDraft: Codable, Hashable, Sendable {
    public let goal: String
    public let rationale: String
    public let draft: RecipeDraft
}

public struct RecipeAIDraftOption: Codable, Identifiable, Hashable, Sendable {
    public let optionId: String
    public let label: String
    public let rationale: String
    public let draft: RecipeDraft

    public var id: String { optionId }
}

public struct RecipeAIOptions: Codable, Hashable, Sendable {
    public let goal: String
    public let rationale: String
    public let options: [RecipeAIDraftOption]
}

public struct AssistantToolCall: Codable, Identifiable, Hashable, Sendable {
    public let callId: String
    public let name: String
    public let arguments: [String: SimmerSmithJSONValue]
    public let ok: Bool
    public let detail: String
    public let status: String
    public let startedAt: Date?
    public let completedAt: Date?

    public var id: String { callId }

    public init(
        callId: String,
        name: String,
        arguments: [String: SimmerSmithJSONValue] = [:],
        ok: Bool = true,
        detail: String = "",
        status: String = "completed",
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.callId = callId
        self.name = name
        self.arguments = arguments
        self.ok = ok
        self.detail = detail
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        // Custom decoder because `assistant.tool_call` (running state) doesn't
        // carry `ok`/`detail` — only `assistant.tool_result` does. Synthesized
        // Decodable would reject those partial payloads and break the SSE
        // stream. Defaults mirror the init above.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callId = try container.decode(String.self, forKey: .callId)
        name = try container.decode(String.self, forKey: .name)
        arguments = (try container.decodeIfPresent([String: SimmerSmithJSONValue].self, forKey: .arguments)) ?? [:]
        ok = (try container.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
        detail = (try container.decodeIfPresent(String.self, forKey: .detail)) ?? ""
        status = (try container.decodeIfPresent(String.self, forKey: .status)) ?? "running"
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

public struct AssistantThreadSummary: Codable, Identifiable, Hashable, Sendable {
    public let threadId: String
    public let title: String
    public let preview: String
    public let threadKind: String
    public let linkedWeekId: String?
    public let createdAt: Date
    public let updatedAt: Date

    public var id: String { threadId }

    public init(
        threadId: String,
        title: String,
        preview: String,
        threadKind: String = "chat",
        linkedWeekId: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.threadId = threadId
        self.title = title
        self.preview = preview
        self.threadKind = threadKind
        self.linkedWeekId = linkedWeekId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decode(String.self, forKey: .threadId)
        title = try container.decode(String.self, forKey: .title)
        preview = (try container.decodeIfPresent(String.self, forKey: .preview)) ?? ""
        threadKind = (try container.decodeIfPresent(String.self, forKey: .threadKind)) ?? "chat"
        linkedWeekId = try container.decodeIfPresent(String.self, forKey: .linkedWeekId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public struct AssistantMessage: Codable, Identifiable, Hashable, Sendable {
    public let messageId: String
    public let threadId: String
    public let role: String
    public let status: String
    public let contentMarkdown: String
    public let recipeDraft: RecipeDraft?
    public let attachedRecipeId: String?
    public let toolCalls: [AssistantToolCall]
    public let createdAt: Date
    public let completedAt: Date?
    public let error: String

    public var id: String { messageId }

    public init(
        messageId: String,
        threadId: String,
        role: String,
        status: String,
        contentMarkdown: String,
        recipeDraft: RecipeDraft?,
        attachedRecipeId: String?,
        toolCalls: [AssistantToolCall] = [],
        createdAt: Date,
        completedAt: Date?,
        error: String
    ) {
        self.messageId = messageId
        self.threadId = threadId
        self.role = role
        self.status = status
        self.contentMarkdown = contentMarkdown
        self.recipeDraft = recipeDraft
        self.attachedRecipeId = attachedRecipeId
        self.toolCalls = toolCalls
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        threadId = try container.decode(String.self, forKey: .threadId)
        role = try container.decode(String.self, forKey: .role)
        status = try container.decode(String.self, forKey: .status)
        contentMarkdown = (try container.decodeIfPresent(String.self, forKey: .contentMarkdown)) ?? ""
        recipeDraft = try container.decodeIfPresent(RecipeDraft.self, forKey: .recipeDraft)
        attachedRecipeId = try container.decodeIfPresent(String.self, forKey: .attachedRecipeId)
        toolCalls = (try container.decodeIfPresent([AssistantToolCall].self, forKey: .toolCalls)) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        error = (try container.decodeIfPresent(String.self, forKey: .error)) ?? ""
    }
}

public struct AssistantThread: Codable, Identifiable, Hashable, Sendable {
    public let threadId: String
    public let title: String
    public let preview: String
    public let threadKind: String
    public let linkedWeekId: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let messages: [AssistantMessage]

    public var id: String { threadId }

    public init(
        threadId: String,
        title: String,
        preview: String,
        threadKind: String = "chat",
        linkedWeekId: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        messages: [AssistantMessage]
    ) {
        self.threadId = threadId
        self.title = title
        self.preview = preview
        self.threadKind = threadKind
        self.linkedWeekId = linkedWeekId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decode(String.self, forKey: .threadId)
        title = try container.decode(String.self, forKey: .title)
        preview = (try container.decodeIfPresent(String.self, forKey: .preview)) ?? ""
        threadKind = (try container.decodeIfPresent(String.self, forKey: .threadKind)) ?? "chat"
        linkedWeekId = try container.decodeIfPresent(String.self, forKey: .linkedWeekId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messages = (try container.decodeIfPresent([AssistantMessage].self, forKey: .messages)) ?? []
    }
}

public struct AssistantPageContextPayload: Codable, Hashable, Sendable {
    public let pageType: String
    public let pageLabel: String
    public let weekId: String?
    public let weekStart: String?
    public let weekStatus: String?
    public let focusDate: String?
    public let focusDayName: String?
    public let recipeId: String?
    public let recipeName: String?
    public let groceryItemCount: Int?
    public let briefSummary: String

    public init(
        pageType: String,
        pageLabel: String = "",
        weekId: String? = nil,
        weekStart: String? = nil,
        weekStatus: String? = nil,
        focusDate: String? = nil,
        focusDayName: String? = nil,
        recipeId: String? = nil,
        recipeName: String? = nil,
        groceryItemCount: Int? = nil,
        briefSummary: String = ""
    ) {
        self.pageType = pageType
        self.pageLabel = pageLabel
        self.weekId = weekId
        self.weekStart = weekStart
        self.weekStatus = weekStatus
        self.focusDate = focusDate
        self.focusDayName = focusDayName
        self.recipeId = recipeId
        self.recipeName = recipeName
        self.groceryItemCount = groceryItemCount
        self.briefSummary = briefSummary
    }
}

public struct AssistantRespondRequestBody: Codable, Hashable, Sendable {
    public let text: String
    public let attachedRecipeId: String?
    public let attachedRecipeDraft: RecipeDraft?
    public let intent: String
    public let pageContext: AssistantPageContextPayload?

    public init(
        text: String,
        attachedRecipeId: String? = nil,
        attachedRecipeDraft: RecipeDraft? = nil,
        intent: String = "general",
        pageContext: AssistantPageContextPayload? = nil
    ) {
        self.text = text
        self.attachedRecipeId = attachedRecipeId
        self.attachedRecipeDraft = attachedRecipeDraft
        self.intent = intent
        self.pageContext = pageContext
    }
}

public struct AssistantStreamEnvelope: Sendable {
    public let event: String
    public let data: Data

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try SimmerSmithJSONCoding.makeDecoder().decode(T.self, from: data)
    }
}

public struct SubstitutionSuggestion: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let reason: String
    public let quantity: String
    public let unit: String

    public var id: String { name }

    public init(name: String, reason: String = "", quantity: String = "", unit: String = "") {
        self.name = name
        self.reason = reason
        self.quantity = quantity
        self.unit = unit
    }
}

public struct IngredientSubstituteResponse: Codable, Hashable, Sendable {
    public let ingredientId: String
    public let originalName: String
    public let suggestions: [SubstitutionSuggestion]

    public init(
        ingredientId: String,
        originalName: String,
        suggestions: [SubstitutionSuggestion]
    ) {
        self.ingredientId = ingredientId
        self.originalName = originalName
        self.suggestions = suggestions
    }
}

public struct RecipeSummary: Codable, Identifiable, Hashable, Sendable {
    public let recipeId: String
    public let recipeTemplateId: String?
    public let baseRecipeId: String?
    public let name: String
    public let mealType: String
    public let cuisine: String
    public let servings: Double?
    public let prepMinutes: Int?
    public let cookMinutes: Int?
    public let tags: [String]
    public let instructionsSummary: String
    public let favorite: Bool
    public let archived: Bool
    public let source: String
    public let sourceLabel: String
    public let sourceUrl: String
    public let notes: String
    public let memories: String
    public let lastUsed: Date?
    public let familyLastUsed: Date?
    public let daysSinceLastUsed: Int?
    public let familyDaysSinceLastUsed: Int?
    public let isVariant: Bool
    public let overrideFields: [String]
    public let variantCount: Int
    public let sourceRecipeCount: Int
    public let archivedAt: Date?
    public let updatedAt: Date
    public let ingredients: [RecipeIngredient]
    public let steps: [RecipeStep]
    public let nutritionSummary: NutritionSummary?

    public var id: String { recipeId }

    enum CodingKeys: String, CodingKey {
        case recipeId
        case recipeTemplateId
        case baseRecipeId
        case name
        case mealType
        case cuisine
        case servings
        case prepMinutes
        case cookMinutes
        case tags
        case instructionsSummary
        case favorite
        case archived
        case source
        case sourceLabel
        case sourceUrl
        case notes
        case memories
        case lastUsed
        case familyLastUsed
        case daysSinceLastUsed
        case familyDaysSinceLastUsed
        case isVariant
        case overrideFields
        case variantCount
        case sourceRecipeCount
        case archivedAt
        case updatedAt
        case ingredients
        case steps
        case nutritionSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipeId = try container.decode(String.self, forKey: .recipeId)
        recipeTemplateId = try container.decodeIfPresent(String.self, forKey: .recipeTemplateId)
        baseRecipeId = try container.decodeIfPresent(String.self, forKey: .baseRecipeId)
        name = try container.decode(String.self, forKey: .name)
        mealType = try container.decodeIfPresent(String.self, forKey: .mealType) ?? ""
        cuisine = try container.decodeIfPresent(String.self, forKey: .cuisine) ?? ""
        servings = try container.decodeIfPresent(Double.self, forKey: .servings)
        prepMinutes = try container.decodeIfPresent(Int.self, forKey: .prepMinutes)
        cookMinutes = try container.decodeIfPresent(Int.self, forKey: .cookMinutes)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        instructionsSummary = try container.decodeIfPresent(String.self, forKey: .instructionsSummary) ?? ""
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        sourceUrl = try container.decodeIfPresent(String.self, forKey: .sourceUrl) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        memories = try container.decodeIfPresent(String.self, forKey: .memories) ?? ""
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        familyLastUsed = try container.decodeIfPresent(Date.self, forKey: .familyLastUsed)
        daysSinceLastUsed = try container.decodeIfPresent(Int.self, forKey: .daysSinceLastUsed)
        familyDaysSinceLastUsed = try container.decodeIfPresent(Int.self, forKey: .familyDaysSinceLastUsed)
        isVariant = try container.decodeIfPresent(Bool.self, forKey: .isVariant) ?? false
        overrideFields = try container.decodeIfPresent([String].self, forKey: .overrideFields) ?? []
        variantCount = try container.decodeIfPresent(Int.self, forKey: .variantCount) ?? 0
        sourceRecipeCount = try container.decodeIfPresent(Int.self, forKey: .sourceRecipeCount) ?? 1
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        ingredients = try container.decodeIfPresent([RecipeIngredient].self, forKey: .ingredients) ?? []
        steps = try container.decodeIfPresent([RecipeStep].self, forKey: .steps) ?? []
        nutritionSummary = try container.decodeIfPresent(NutritionSummary.self, forKey: .nutritionSummary)
    }
}

public struct RetailerPrice: Codable, Identifiable, Hashable, Sendable {
    public let retailer: String
    public let status: String
    public let storeName: String
    public let productName: String
    public let packageSize: String
    public let unitPrice: Double?
    public let linePrice: Double?
    public let productUrl: String
    public let availability: String
    public let candidateScore: Double?
    public let reviewNote: String
    public let rawQuery: String
    public let scrapedAt: Date?

    public var id: String { "\(retailer)-\(productName)-\(packageSize)" }
}

public struct GroceryItem: Codable, Identifiable, Hashable, Sendable {
    public let groceryItemId: String
    public let ingredientName: String
    public let normalizedName: String
    public let baseIngredientId: String?
    public let baseIngredientName: String?
    public let ingredientVariationId: String?
    public let ingredientVariationName: String?
    public let resolutionStatus: String
    public let totalQuantity: Double?
    public let unit: String
    public let quantityText: String
    public let category: String
    public let sourceMeals: String
    public let notes: String
    public let reviewFlag: String
    public let updatedAt: Date
    public let retailerPrices: [RetailerPrice]

    public var id: String { groceryItemId }

    enum CodingKeys: String, CodingKey {
        case groceryItemId
        case ingredientName
        case normalizedName
        case baseIngredientId
        case baseIngredientName
        case ingredientVariationId
        case ingredientVariationName
        case resolutionStatus
        case totalQuantity
        case unit
        case quantityText
        case category
        case sourceMeals
        case notes
        case reviewFlag
        case updatedAt
        case retailerPrices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groceryItemId = try container.decode(String.self, forKey: .groceryItemId)
        ingredientName = try container.decode(String.self, forKey: .ingredientName)
        normalizedName = try container.decode(String.self, forKey: .normalizedName)
        baseIngredientId = try container.decodeIfPresent(String.self, forKey: .baseIngredientId)
        baseIngredientName = try container.decodeIfPresent(String.self, forKey: .baseIngredientName)
        ingredientVariationId = try container.decodeIfPresent(String.self, forKey: .ingredientVariationId)
        ingredientVariationName = try container.decodeIfPresent(String.self, forKey: .ingredientVariationName)
        resolutionStatus = try container.decodeIfPresent(String.self, forKey: .resolutionStatus) ?? "unresolved"
        totalQuantity = try container.decodeIfPresent(Double.self, forKey: .totalQuantity)
        unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        quantityText = try container.decodeIfPresent(String.self, forKey: .quantityText) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        sourceMeals = try container.decodeIfPresent(String.self, forKey: .sourceMeals) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        reviewFlag = try container.decodeIfPresent(String.self, forKey: .reviewFlag) ?? ""
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        retailerPrices = try container.decodeIfPresent([RetailerPrice].self, forKey: .retailerPrices) ?? []
    }
}

public struct WeekMeal: Codable, Identifiable, Hashable, Sendable {
    public let mealId: String
    public let dayName: String
    public let mealDate: Date
    public let slot: String
    public let recipeId: String?
    public let recipeName: String
    public let servings: Double?
    public let scaleMultiplier: Double
    public let source: String
    public let approved: Bool
    public let notes: String
    public let aiGenerated: Bool
    public let updatedAt: Date
    public let ingredients: [RecipeIngredient]
    public let macros: MacroBreakdown?

    public var id: String { mealId }

    enum CodingKeys: String, CodingKey {
        case mealId
        case dayName
        case mealDate
        case slot
        case recipeId
        case recipeName
        case servings
        case scaleMultiplier
        case source
        case approved
        case notes
        case aiGenerated
        case updatedAt
        case ingredients
        case macros
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mealId = try container.decode(String.self, forKey: .mealId)
        dayName = try container.decode(String.self, forKey: .dayName)
        mealDate = try container.decode(Date.self, forKey: .mealDate)
        slot = try container.decode(String.self, forKey: .slot)
        recipeId = try container.decodeIfPresent(String.self, forKey: .recipeId)
        recipeName = try container.decode(String.self, forKey: .recipeName)
        servings = try container.decodeIfPresent(Double.self, forKey: .servings)
        scaleMultiplier = try container.decodeIfPresent(Double.self, forKey: .scaleMultiplier) ?? 1.0
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "user"
        approved = try container.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        aiGenerated = try container.decodeIfPresent(Bool.self, forKey: .aiGenerated) ?? false
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        ingredients = try container.decodeIfPresent([RecipeIngredient].self, forKey: .ingredients) ?? []
        macros = try container.decodeIfPresent(MacroBreakdown.self, forKey: .macros)
    }
}

public struct WeekSnapshot: Codable, Identifiable, Sendable {
    public let weekId: String
    public let weekStart: Date
    public let weekEnd: Date
    public let status: String
    public let notes: String
    public let readyForAiAt: Date?
    public let approvedAt: Date?
    public let pricedAt: Date?
    public let updatedAt: Date
    public let stagedChangeCount: Int
    public let feedbackCount: Int
    public let exportCount: Int
    public let meals: [WeekMeal]
    public let groceryItems: [GroceryItem]
    public let nutritionTotals: [DailyNutrition]
    public let weeklyTotals: MacroBreakdown?

    public var id: String { weekId }

    enum CodingKeys: String, CodingKey {
        case weekId
        case weekStart
        case weekEnd
        case status
        case notes
        case readyForAiAt
        case approvedAt
        case pricedAt
        case updatedAt
        case stagedChangeCount
        case feedbackCount
        case exportCount
        case meals
        case groceryItems
        case nutritionTotals
        case weeklyTotals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekId = try container.decode(String.self, forKey: .weekId)
        weekStart = try container.decode(Date.self, forKey: .weekStart)
        weekEnd = try container.decode(Date.self, forKey: .weekEnd)
        status = try container.decode(String.self, forKey: .status)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        readyForAiAt = try container.decodeIfPresent(Date.self, forKey: .readyForAiAt)
        approvedAt = try container.decodeIfPresent(Date.self, forKey: .approvedAt)
        pricedAt = try container.decodeIfPresent(Date.self, forKey: .pricedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        stagedChangeCount = try container.decodeIfPresent(Int.self, forKey: .stagedChangeCount) ?? 0
        feedbackCount = try container.decodeIfPresent(Int.self, forKey: .feedbackCount) ?? 0
        exportCount = try container.decodeIfPresent(Int.self, forKey: .exportCount) ?? 0
        meals = try container.decodeIfPresent([WeekMeal].self, forKey: .meals) ?? []
        groceryItems = try container.decodeIfPresent([GroceryItem].self, forKey: .groceryItems) ?? []
        nutritionTotals = try container.decodeIfPresent([DailyNutrition].self, forKey: .nutritionTotals) ?? []
        weeklyTotals = try container.decodeIfPresent(MacroBreakdown.self, forKey: .weeklyTotals)
    }
}

public struct WeekSummary: Codable, Identifiable, Hashable, Sendable {
    public let weekId: String
    public let weekStart: Date
    public let weekEnd: Date
    public let status: String
    public let notes: String
    public let readyForAiAt: Date?
    public let approvedAt: Date?
    public let pricedAt: Date?
    public let updatedAt: Date
    public let mealCount: Int
    public let groceryItemCount: Int
    public let stagedChangeCount: Int
    public let feedbackCount: Int
    public let exportCount: Int

    public var id: String { weekId }
}

public struct MealUpdateRequest: Codable, Sendable, Hashable {
    public let mealId: String?
    public let dayName: String
    public let mealDate: Date
    public let slot: String
    public let recipeId: String?
    public let recipeName: String
    public let servings: Double?
    public let scaleMultiplier: Double
    public let notes: String
    public let approved: Bool

    public init(
        mealId: String? = nil,
        dayName: String,
        mealDate: Date,
        slot: String,
        recipeId: String? = nil,
        recipeName: String,
        servings: Double? = nil,
        scaleMultiplier: Double = 1.0,
        notes: String = "",
        approved: Bool = false
    ) {
        self.mealId = mealId
        self.dayName = dayName
        self.mealDate = mealDate
        self.slot = slot
        self.recipeId = recipeId
        self.recipeName = recipeName
        self.servings = servings
        self.scaleMultiplier = scaleMultiplier
        self.notes = notes
        self.approved = approved
    }
}

public struct WeekCreateRequest: Codable, Sendable {
    public let weekStart: Date
    public let notes: String

    public init(weekStart: Date, notes: String = "") {
        self.weekStart = weekStart
        self.notes = notes
    }
}

public struct ExportItem: Codable, Identifiable, Hashable, Sendable {
    public let exportItemId: String
    public let sortOrder: Int
    public let listName: String
    public let title: String
    public let notes: String
    public let metadataJson: String
    public let status: String

    public var id: String { exportItemId }
}

public struct ExportRun: Codable, Identifiable, Hashable, Sendable {
    public let exportId: String
    public let destination: String
    public let exportType: String
    public let status: String
    public let itemCount: Int
    public let payloadJson: String
    public let error: String
    public let externalRef: String
    public let createdAt: Date
    public let completedAt: Date?
    public let updatedAt: Date
    public let items: [ExportItem]

    public var id: String { exportId }
}

public struct WeekFeedbackSummary: Codable, Sendable {
    public let totalEntries: Int
    public let mealEntries: Int
    public let ingredientEntries: Int
    public let brandEntries: Int
    public let shoppingEntries: Int
    public let storeEntries: Int
    public let weekEntries: Int
}

public struct FeedbackEntryResponse: Codable, Identifiable, Hashable, Sendable {
    public let feedbackId: String
    public let mealId: String?
    public let groceryItemId: String?
    public let targetType: String
    public let targetName: String
    public let normalizedName: String?
    public let retailer: String
    public let sentiment: Int
    public let reasonCodes: [String]
    public let notes: String
    public let source: String
    public let active: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public var id: String { feedbackId }
}

public struct WeekFeedbackResponse: Codable, Sendable {
    public let weekId: String
    public let summary: WeekFeedbackSummary
    public let entries: [FeedbackEntryResponse]
}

public struct FeedbackEntryRequest: Codable, Sendable {
    public let feedbackId: String?
    public let mealId: String?
    public let groceryItemId: String?
    public let targetType: String
    public let targetName: String
    public let normalizedName: String?
    public let retailer: String
    public let sentiment: Int
    public let reasonCodes: [String]
    public let notes: String
    public let source: String
    public let active: Bool

    public init(
        feedbackId: String? = nil,
        mealId: String? = nil,
        groceryItemId: String? = nil,
        targetType: String,
        targetName: String,
        normalizedName: String? = nil,
        retailer: String = "",
        sentiment: Int,
        reasonCodes: [String] = [],
        notes: String = "",
        source: String = "ios",
        active: Bool = true
    ) {
        self.feedbackId = feedbackId
        self.mealId = mealId
        self.groceryItemId = groceryItemId
        self.targetType = targetType
        self.targetName = targetName
        self.normalizedName = normalizedName
        self.retailer = retailer
        self.sentiment = sentiment
        self.reasonCodes = reasonCodes
        self.notes = notes
        self.source = source
        self.active = active
    }
}

// MARK: - Stores & Pricing

public struct StoreLocation: Codable, Identifiable, Sendable {
    public let locationId: String
    public let name: String
    public let chain: String
    public let address: String
    public let city: String
    public let state: String
    public let zipCode: String
    public let phone: String

    public var id: String { locationId }

    public var displayName: String {
        if chain.isEmpty || chain == name {
            return "\(name) — \(city), \(state)"
        }
        return "\(chain) (\(name)) — \(city), \(state)"
    }
}

public struct PricingResponse: Codable, Sendable {
    public let weekId: String
    public let weekStart: Date
    public let totals: [String: Double]
    public let items: [GroceryItem]
}
