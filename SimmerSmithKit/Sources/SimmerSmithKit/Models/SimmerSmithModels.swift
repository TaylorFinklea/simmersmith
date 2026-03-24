import Foundation

public struct HealthResponse: Codable, Sendable {
    public let status: String
}

public struct Staple: Codable, Identifiable, Hashable, Sendable {
    public let stapleName: String
    public let normalizedName: String
    public let notes: String
    public let isActive: Bool

    public var id: String { normalizedName }
}

public struct ProfileSnapshot: Codable, Sendable {
    public let updatedAt: Date?
    public let settings: [String: String]
    public let staples: [Staple]
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

public struct RecipeIngredient: Codable, Identifiable, Hashable, Sendable {
    public var ingredientId: String?
    public var ingredientName: String
    public var normalizedName: String?
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
        quantity: Double? = nil,
        unit: String = "",
        prep: String = "",
        category: String = "",
        notes: String = ""
    ) {
        self.ingredientId = ingredientId
        self.ingredientName = ingredientName
        self.normalizedName = normalizedName
        self.quantity = quantity
        self.unit = unit
        self.prep = prep
        self.category = category
        self.notes = notes
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

public struct RecipeSummary: Codable, Identifiable, Hashable, Sendable {
    public let recipeId: String
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

    public var id: String { weekId }
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
