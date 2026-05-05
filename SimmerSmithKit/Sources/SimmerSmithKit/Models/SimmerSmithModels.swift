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

// MARK: - Household sharing (M21)

public struct HouseholdMember: Codable, Sendable, Hashable, Identifiable {
    public let userId: String
    public let role: String
    public let joinedAt: Date

    public var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId
        case role
        case joinedAt
    }
}

public struct HouseholdInvitation: Codable, Sendable, Hashable, Identifiable {
    public let code: String
    public let createdAt: Date
    public let expiresAt: Date
    public let createdByUserId: String

    public var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code
        case createdAt
        case expiresAt
        case createdByUserId
    }
}

public struct HouseholdSnapshot: Codable, Sendable {
    public let householdId: String
    public let name: String
    public let createdByUserId: String
    /// Role of the requesting user within this household: `"owner"` or `"member"`.
    public let role: String
    public let members: [HouseholdMember]
    public let activeInvitations: [HouseholdInvitation]

    public var isOwner: Bool { role == "owner" }
    public var isSolo: Bool { members.count == 1 }

    enum CodingKeys: String, CodingKey {
        case householdId
        case name
        case createdByUserId
        case role
        case members
        case activeInvitations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        householdId = try container.decode(String.self, forKey: .householdId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        createdByUserId = try container.decode(String.self, forKey: .createdByUserId)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "member"
        members = try container.decodeIfPresent([HouseholdMember].self, forKey: .members) ?? []
        activeInvitations = try container.decodeIfPresent(
            [HouseholdInvitation].self, forKey: .activeInvitations
        ) ?? []
    }
}

public struct InvitationCreated: Codable, Sendable {
    public let code: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt
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
    public let sourceUrl: String
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
    /// M25 catalog ownership. NULL = global (approved master). Non-
    /// null = household-private (submission_status drives whether
    /// it's submitted, household_only, or rejected).
    public let householdId: String?
    /// M25 submission lifecycle: `approved` / `submitted` /
    /// `household_only` / `rejected`. iOS surfaces this via row
    /// chips in IngredientsView and the inline link picker.
    public let submissionStatus: String
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
        sourceUrl: String = "",
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
        householdId: String? = nil,
        submissionStatus: String = "approved",
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
        self.sourceUrl = sourceUrl
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
        self.householdId = householdId
        self.submissionStatus = submissionStatus
        self.updatedAt = updatedAt
    }

    /// Custom decoder so the new M25 fields (`householdId`,
    /// `submissionStatus`) decode safely against pre-M25 server
    /// responses or fixtures that don't include them yet. Treat
    /// missing `submissionStatus` as `approved` (the historical
    /// default; everything was global before M25).
    private enum CodingKeys: String, CodingKey {
        case baseIngredientId, name, normalizedName, category, defaultUnit, notes
        case sourceName, sourceRecordId, sourceUrl
        case provisional, active
        case nutritionReferenceAmount, nutritionReferenceUnit, calories
        case archivedAt, mergedIntoId
        case variationCount, preferenceCount, recipeUsageCount, groceryUsageCount
        case productLike, householdId, submissionStatus, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseIngredientId = try c.decode(String.self, forKey: .baseIngredientId)
        name = try c.decode(String.self, forKey: .name)
        normalizedName = try c.decode(String.self, forKey: .normalizedName)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        defaultUnit = try c.decodeIfPresent(String.self, forKey: .defaultUnit) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourceRecordId = try c.decodeIfPresent(String.self, forKey: .sourceRecordId) ?? ""
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl) ?? ""
        provisional = try c.decodeIfPresent(Bool.self, forKey: .provisional) ?? false
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        nutritionReferenceAmount = try c.decodeIfPresent(Double.self, forKey: .nutritionReferenceAmount)
        nutritionReferenceUnit = try c.decodeIfPresent(String.self, forKey: .nutritionReferenceUnit) ?? ""
        calories = try c.decodeIfPresent(Double.self, forKey: .calories)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        mergedIntoId = try c.decodeIfPresent(String.self, forKey: .mergedIntoId)
        variationCount = try c.decodeIfPresent(Int.self, forKey: .variationCount) ?? 0
        preferenceCount = try c.decodeIfPresent(Int.self, forKey: .preferenceCount) ?? 0
        recipeUsageCount = try c.decodeIfPresent(Int.self, forKey: .recipeUsageCount) ?? 0
        groceryUsageCount = try c.decodeIfPresent(Int.self, forKey: .groceryUsageCount) ?? 0
        productLike = try c.decodeIfPresent(Bool.self, forKey: .productLike) ?? false
        householdId = try c.decodeIfPresent(String.self, forKey: .householdId)
        submissionStatus = try c.decodeIfPresent(String.self, forKey: .submissionStatus) ?? "approved"
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
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
    public let sourceUrl: String
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
        sourceUrl: String = "",
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
        self.sourceUrl = sourceUrl
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
    /// M24: rank=1 is the primary brand pick; rank=2 is the secondary
    /// fallback used by the M23 cart-automation skill when the
    /// primary is out of stock. Higher ranks are valid; iOS surfaces
    /// 1-3 in the editor today.
    public let rank: Int
    public let updatedAt: Date

    public var id: String { preferenceId }

    enum CodingKeys: String, CodingKey {
        case preferenceId, baseIngredientId, baseIngredientName,
             preferredVariationId, preferredVariationName,
             preferredBrand, choiceMode, active, notes, rank, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferenceId = try c.decode(String.self, forKey: .preferenceId)
        baseIngredientId = try c.decode(String.self, forKey: .baseIngredientId)
        baseIngredientName = try c.decode(String.self, forKey: .baseIngredientName)
        preferredVariationId = try c.decodeIfPresent(String.self, forKey: .preferredVariationId)
        preferredVariationName = try c.decodeIfPresent(String.self, forKey: .preferredVariationName)
        preferredBrand = try c.decodeIfPresent(String.self, forKey: .preferredBrand) ?? ""
        choiceMode = try c.decodeIfPresent(String.self, forKey: .choiceMode) ?? "preferred"
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? 1
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
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
    public var difficultyScore: Int?
    public var kidFriendly: Bool
    public var ingredients: [RecipeIngredient]
    public var steps: [RecipeStep]
    public var nutritionSummary: NutritionSummary?
    public var imageUrl: String?

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
        difficultyScore: Int? = nil,
        kidFriendly: Bool = false,
        ingredients: [RecipeIngredient] = [],
        steps: [RecipeStep] = [],
        nutritionSummary: NutritionSummary? = nil,
        imageUrl: String? = nil
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
        self.difficultyScore = difficultyScore
        self.kidFriendly = kidFriendly
        self.ingredients = ingredients
        self.steps = steps
        self.nutritionSummary = nutritionSummary
        self.imageUrl = imageUrl
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
        case difficultyScore
        case kidFriendly
        case ingredients
        case steps
        case nutritionSummary
        case imageUrl = "imageUrl"
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
        difficultyScore = try container.decodeIfPresent(Int.self, forKey: .difficultyScore)
        kidFriendly = try container.decodeIfPresent(Bool.self, forKey: .kidFriendly) ?? false
        ingredients = try container.decodeIfPresent([RecipeIngredient].self, forKey: .ingredients) ?? []
        steps = try container.decodeIfPresent([RecipeStep].self, forKey: .steps) ?? []
        nutritionSummary = try container.decodeIfPresent(NutritionSummary.self, forKey: .nutritionSummary)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
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

/// M26 Phase 5 — when an assistant tool returns a `proposed_change`
/// payload (e.g. `swap_meal` proposes before applying), the iOS
/// client renders a Was→Becomes diff card with Confirm/Cancel
/// buttons. The structured fields below mirror the server-side dict
/// produced by `_run_swap_meal`.
public struct AssistantProposedChange: Codable, Hashable, Sendable {
    public let kind: String
    public let summary: String
    public let beforeRecipeName: String
    public let afterRecipeName: String
    public let dayName: String
    public let slot: String
    public let mealId: String?
    public let confirmTool: String
    public let confirmArgs: [String: SimmerSmithJSONValue]

    /// Decode the loosely-typed `data` blob from a tool result into a
    /// structured proposal. Returns nil when the payload doesn't look
    /// like a proposed_change (so the iOS client knows to fall back
    /// to plain rendering).
    public static func from(_ data: [String: SimmerSmithJSONValue]) -> AssistantProposedChange? {
        guard case let .string(kind) = data["kind"], kind == "proposed_change" else {
            return nil
        }
        let summary = (data["summary"]).flatMap { value -> String? in
            if case let .string(s) = value { return s }
            return nil
        } ?? "Proposed change"
        guard case let .object(before) = data["before"],
              case let .object(after) = data["after"] else {
            return nil
        }
        func str(_ dict: [String: SimmerSmithJSONValue], _ key: String) -> String {
            if case let .string(s) = dict[key] { return s }
            return ""
        }
        let confirmTool = (data["confirm_tool"]).flatMap { value -> String? in
            if case let .string(s) = value { return s }
            return nil
        } ?? "confirm_swap_meal"
        var confirmArgs: [String: SimmerSmithJSONValue] = [:]
        if case let .object(args) = data["confirm_args"] {
            confirmArgs = args
        }
        return AssistantProposedChange(
            kind: kind,
            summary: summary,
            beforeRecipeName: str(before, "recipe_name"),
            afterRecipeName: str(after, "recipe_name"),
            dayName: str(after, "day_name").isEmpty ? str(before, "day_name") : str(after, "day_name"),
            slot: str(after, "slot").isEmpty ? str(before, "slot") : str(after, "slot"),
            mealId: {
                let m = str(before, "meal_id")
                return m.isEmpty ? nil : m
            }(),
            confirmTool: confirmTool,
            confirmArgs: confirmArgs
        )
    }
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
    /// Tool result `data` blob (M26 Phase 5). Carries `proposed_change`
    /// payloads from `swap_meal` so the iOS client can render a diff
    /// card. Nil for tools that don't surface structured data.
    public let data: [String: SimmerSmithJSONValue]?

    public var id: String { callId }

    /// Convenience: parse the `data` payload as a proposed-change card
    /// when present.
    public var proposedChange: AssistantProposedChange? {
        guard let data else { return nil }
        return AssistantProposedChange.from(data)
    }

    public init(
        callId: String,
        name: String,
        arguments: [String: SimmerSmithJSONValue] = [:],
        ok: Bool = true,
        detail: String = "",
        status: String = "completed",
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        data: [String: SimmerSmithJSONValue]? = nil
    ) {
        self.callId = callId
        self.name = name
        self.arguments = arguments
        self.ok = ok
        self.detail = detail
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.data = data
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
        data = try container.decodeIfPresent([String: SimmerSmithJSONValue].self, forKey: .data)
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

// MARK: - Seasonal produce (M12)

public struct InSeasonItem: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let whyNow: String
    public let peakScore: Int

    public var id: String { name }

    public init(name: String, whyNow: String = "", peakScore: Int = 3) {
        self.name = name
        self.whyNow = whyNow
        self.peakScore = peakScore
    }
}

// MARK: - Recipe memories log (M15)

/// One time-stamped memory entry on a recipe — body text plus an
/// optional photo. The server returns `photoUrl` already pointing
/// at `/api/recipes/{recipeId}/memories/{id}/photo?v=...` when a
/// photo exists; the iOS view layer fetches bytes through the
/// authenticated session (mirrors the M14 RecipeHeaderImage flow).
public struct RecipeMemory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let body: String
    public let createdAt: Date
    public let photoUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case createdAt
        case photoUrl = "photoUrl"
    }
}

// MARK: - Pairings (M12)

public struct PairingOption: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let role: String
    public let reason: String

    public var id: String { name }

    public init(name: String, role: String, reason: String = "") {
        self.name = name
        self.role = role
        self.reason = reason
    }
}

public struct RecipePairings: Codable, Hashable, Sendable {
    public let recipeId: String
    public let suggestions: [PairingOption]

    public init(recipeId: String, suggestions: [PairingOption]) {
        self.recipeId = recipeId
        self.suggestions = suggestions
    }
}

// MARK: - Vision (M11)

public struct CuisineUse: Codable, Hashable, Sendable {
    public let country: String
    public let dish: String

    public init(country: String, dish: String) {
        self.country = country
        self.dish = dish
    }
}

public struct IngredientIdentification: Codable, Hashable, Sendable {
    public let name: String
    public let confidence: String
    public let commonNames: [String]
    public let cuisineUses: [CuisineUse]
    public let recipeMatchTerms: [String]
    public let notes: String

    public init(
        name: String,
        confidence: String,
        commonNames: [String] = [],
        cuisineUses: [CuisineUse] = [],
        recipeMatchTerms: [String] = [],
        notes: String = ""
    ) {
        self.name = name
        self.confidence = confidence
        self.commonNames = commonNames
        self.cuisineUses = cuisineUses
        self.recipeMatchTerms = recipeMatchTerms
        self.notes = notes
    }
}

public struct CookCheckResult: Codable, Hashable, Sendable {
    public let verdict: String
    public let tip: String
    public let suggestedMinutesRemaining: Int

    public init(verdict: String, tip: String, suggestedMinutesRemaining: Int = 0) {
        self.verdict = verdict
        self.tip = tip
        self.suggestedMinutesRemaining = suggestedMinutesRemaining
    }
}

public struct ProductLookup: Codable, Hashable, Sendable {
    public let productId: String
    public let upc: String
    public let brand: String
    public let description: String
    public let packageSize: String
    public let regularPrice: Double?
    public let promoPrice: Double?
    public let productUrl: String
    public let inStock: Bool

    public init(
        productId: String,
        upc: String,
        brand: String,
        description: String,
        packageSize: String,
        regularPrice: Double?,
        promoPrice: Double?,
        productUrl: String,
        inStock: Bool
    ) {
        self.productId = productId
        self.upc = upc
        self.brand = brand
        self.description = description
        self.packageSize = packageSize
        self.regularPrice = regularPrice
        self.promoPrice = promoPrice
        self.productUrl = productUrl
        self.inStock = inStock
    }
}

// MARK: - Event Plans (M10)

public struct Guest: Codable, Identifiable, Hashable, Sendable {
    public let guestId: String
    public var name: String
    public var relationshipLabel: String
    public var dietaryNotes: String
    public var allergies: String
    /// Coarse life stage: "baby", "toddler", "child", "teen", "adult".
    /// The AI uses this to size portions + pick age-appropriate dishes
    /// (no whole grapes for toddlers, no raw fish for infants, etc.).
    public var ageGroup: String
    public var active: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public var id: String { guestId }

    public init(
        guestId: String,
        name: String,
        relationshipLabel: String = "",
        dietaryNotes: String = "",
        allergies: String = "",
        ageGroup: String = "adult",
        active: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.guestId = guestId
        self.name = name
        self.relationshipLabel = relationshipLabel
        self.dietaryNotes = dietaryNotes
        self.allergies = allergies
        self.ageGroup = ageGroup
        self.active = active
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct EventAttendee: Codable, Identifiable, Hashable, Sendable {
    public let guestId: String
    public let plusOnes: Int
    public let guest: Guest

    public var id: String { guestId }

    public init(guestId: String, plusOnes: Int, guest: Guest) {
        self.guestId = guestId
        self.plusOnes = plusOnes
        self.guest = guest
    }
}

public struct EventMealIngredient: Codable, Identifiable, Hashable, Sendable {
    public let ingredientId: String
    public let ingredientName: String
    public let baseIngredientId: String?
    public let ingredientVariationId: String?
    public let quantity: Double?
    public let unit: String
    public let prep: String
    public let category: String
    public let notes: String

    public var id: String { ingredientId }
}

public struct EventMeal: Codable, Identifiable, Hashable, Sendable {
    public let mealId: String
    public let role: String
    public let recipeId: String?
    public let recipeName: String
    public let servings: Double?
    public let scaleMultiplier: Double
    public let notes: String
    public let sortOrder: Int
    public let aiGenerated: Bool
    public let approved: Bool
    /// Optional: the guest_id of the person bringing this dish. Null
    /// means the host is cooking it.
    public let assignedGuestId: String?
    /// List of guest_ids this dish is compatible with. Empty = safe for
    /// all. Populated by the AI menu generator in Phase 2.
    public let constraintCoverage: [String]
    public let ingredients: [EventMealIngredient]
    public let createdAt: Date
    public let updatedAt: Date

    public var id: String { mealId }
}

public struct EventGroceryItem: Codable, Identifiable, Hashable, Sendable {
    public let groceryItemId: String
    public let ingredientName: String
    public let baseIngredientId: String?
    public let ingredientVariationId: String?
    public let totalQuantity: Double?
    public let unit: String
    public let quantityText: String
    public let category: String
    public let sourceMeals: [String]
    public let notes: String
    public let reviewFlag: String
    public let mergedIntoWeekId: String?
    public let mergedIntoGroceryItemId: String?

    public var id: String { groceryItemId }
}

public struct EventSummary: Codable, Identifiable, Hashable, Sendable {
    public let eventId: String
    public let name: String
    public let eventDate: Date?
    public let occasion: String
    public let attendeeCount: Int
    public let status: String
    public let linkedWeekId: String?
    public let autoMergeGrocery: Bool
    public let mealCount: Int
    public let createdAt: Date
    public let updatedAt: Date

    public var id: String { eventId }

    public init(
        eventId: String,
        name: String,
        eventDate: Date?,
        occasion: String,
        attendeeCount: Int,
        status: String,
        linkedWeekId: String?,
        autoMergeGrocery: Bool = true,
        mealCount: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.eventId = eventId
        self.name = name
        self.eventDate = eventDate
        self.occasion = occasion
        self.attendeeCount = attendeeCount
        self.status = status
        self.linkedWeekId = linkedWeekId
        self.autoMergeGrocery = autoMergeGrocery
        self.mealCount = mealCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(String.self, forKey: .eventId)
        name = try c.decode(String.self, forKey: .name)
        eventDate = try c.decodeIfPresent(Date.self, forKey: .eventDate)
        occasion = try c.decode(String.self, forKey: .occasion)
        attendeeCount = try c.decode(Int.self, forKey: .attendeeCount)
        status = try c.decode(String.self, forKey: .status)
        linkedWeekId = try c.decodeIfPresent(String.self, forKey: .linkedWeekId)
        autoMergeGrocery = try c.decodeIfPresent(Bool.self, forKey: .autoMergeGrocery) ?? true
        mealCount = try c.decode(Int.self, forKey: .mealCount)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case eventId, name, eventDate, occasion, attendeeCount, status,
             linkedWeekId, autoMergeGrocery, mealCount, createdAt, updatedAt
    }
}

/// M28 phase 2 — additive pantry top-up for an event.
public struct EventPantrySupplement: Codable, Identifiable, Hashable, Sendable {
    public let supplementId: String
    public let pantryItemId: String
    public let pantryItemName: String
    public let quantity: Double
    public let unit: String
    public let notes: String
    public let updatedAt: Date

    public var id: String { supplementId }

    public init(
        supplementId: String,
        pantryItemId: String,
        pantryItemName: String,
        quantity: Double,
        unit: String = "",
        notes: String = "",
        updatedAt: Date = Date()
    ) {
        self.supplementId = supplementId
        self.pantryItemId = pantryItemId
        self.pantryItemName = pantryItemName
        self.quantity = quantity
        self.unit = unit
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

public struct Event: Codable, Identifiable, Hashable, Sendable {
    public let eventId: String
    public let name: String
    public let eventDate: Date?
    public let occasion: String
    public let attendeeCount: Int
    public let status: String
    public let linkedWeekId: String?
    public let autoMergeGrocery: Bool
    public let mealCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let notes: String
    public let attendees: [EventAttendee]
    public let meals: [EventMeal]
    public let groceryItems: [EventGroceryItem]
    public let pantrySupplements: [EventPantrySupplement]

    public var id: String { eventId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(String.self, forKey: .eventId)
        name = try c.decode(String.self, forKey: .name)
        eventDate = try c.decodeIfPresent(Date.self, forKey: .eventDate)
        occasion = try c.decode(String.self, forKey: .occasion)
        attendeeCount = try c.decode(Int.self, forKey: .attendeeCount)
        status = try c.decode(String.self, forKey: .status)
        linkedWeekId = try c.decodeIfPresent(String.self, forKey: .linkedWeekId)
        autoMergeGrocery = try c.decodeIfPresent(Bool.self, forKey: .autoMergeGrocery) ?? true
        mealCount = try c.decode(Int.self, forKey: .mealCount)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        attendees = try c.decodeIfPresent([EventAttendee].self, forKey: .attendees) ?? []
        meals = try c.decodeIfPresent([EventMeal].self, forKey: .meals) ?? []
        groceryItems = try c.decodeIfPresent([EventGroceryItem].self, forKey: .groceryItems) ?? []
        pantrySupplements = try c.decodeIfPresent([EventPantrySupplement].self, forKey: .pantrySupplements) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case eventId, name, eventDate, occasion, attendeeCount, status,
             linkedWeekId, autoMergeGrocery, mealCount, createdAt, updatedAt,
             notes, attendees, meals, groceryItems, pantrySupplements
    }
}

public struct EventMenuResponse: Codable, Hashable, Sendable {
    public let event: Event
    public let coverageSummary: String
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
    public let difficultyScore: Int?
    public let kidFriendly: Bool
    public let ingredients: [RecipeIngredient]
    public let steps: [RecipeStep]
    public let nutritionSummary: NutritionSummary?
    public let imageUrl: String?

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
        case difficultyScore
        case kidFriendly
        case ingredients
        case steps
        case nutritionSummary
        case imageUrl = "imageUrl"
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
        difficultyScore = try container.decodeIfPresent(Int.self, forKey: .difficultyScore)
        kidFriendly = try container.decodeIfPresent(Bool.self, forKey: .kidFriendly) ?? false
        ingredients = try container.decodeIfPresent([RecipeIngredient].self, forKey: .ingredients) ?? []
        steps = try container.decodeIfPresent([RecipeStep].self, forKey: .steps) ?? []
        nutritionSummary = try container.decodeIfPresent(NutritionSummary.self, forKey: .nutritionSummary)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
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
    // M22 mutability fields. `*Override` columns hold the user's
    // explicit value when set; the auto-aggregated value stays in
    // `totalQuantity` / `unit` / `notes` so the UI can show "you
    // overrode 2 → 3 cups, system thinks 2 cups". `isUserAdded` rows
    // are user-curated and never deleted by smart-merge regen.
    // `isUserRemoved` is a tombstone — the server hides these from
    // the regular week payload but exposes them via the delta
    // endpoint so the local Reminders mirror can propagate the
    // removal.
    public let isUserAdded: Bool
    public let isUserRemoved: Bool
    public let quantityOverride: Double?
    public let unitOverride: String?
    public let notesOverride: String?
    public let isChecked: Bool
    public let checkedAt: Date?
    public let checkedByUserId: String?
    /// M22.2: portion contributed by merged events. Display sums
    /// `totalQuantity` (week-meal portion) + `eventQuantity` (event
    /// portion). User override still wins when set.
    public let eventQuantity: Double?
    public let updatedAt: Date
    public let retailerPrices: [RetailerPrice]

    public var id: String { groceryItemId }

    /// Quantity to display: user override wins; otherwise the sum of
    /// the week-meal portion and any merged-event contribution.
    public var effectiveQuantity: Double? {
        if let override = quantityOverride { return override }
        let week = totalQuantity ?? 0
        let event = eventQuantity ?? 0
        if totalQuantity == nil && eventQuantity == nil { return nil }
        return week + event
    }
    /// Unit to display: user override wins over the auto value.
    public var effectiveUnit: String { unitOverride ?? unit }
    /// Notes to display: user override wins over the auto value.
    public var effectiveNotes: String { notesOverride ?? notes }

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
        case isUserAdded
        case isUserRemoved
        case quantityOverride
        case unitOverride
        case notesOverride
        case isChecked
        case checkedAt
        case checkedByUserId
        case eventQuantity
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
        isUserAdded = try container.decodeIfPresent(Bool.self, forKey: .isUserAdded) ?? false
        isUserRemoved = try container.decodeIfPresent(Bool.self, forKey: .isUserRemoved) ?? false
        quantityOverride = try container.decodeIfPresent(Double.self, forKey: .quantityOverride)
        unitOverride = try container.decodeIfPresent(String.self, forKey: .unitOverride)
        notesOverride = try container.decodeIfPresent(String.self, forKey: .notesOverride)
        isChecked = try container.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
        checkedByUserId = try container.decodeIfPresent(String.self, forKey: .checkedByUserId)
        eventQuantity = try container.decodeIfPresent(Double.self, forKey: .eventQuantity)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        retailerPrices = try container.decodeIfPresent([RetailerPrice].self, forKey: .retailerPrices) ?? []
    }
}

/// Response shape from `GET /api/weeks/{id}/grocery?since=...` — used by
/// the Reminders sync engine to fetch only items that changed since
/// the previous poll. Includes tombstones (`isUserRemoved=true`) so
/// the device can detect removals it hasn't yet propagated locally.
public struct GroceryListDelta: Codable, Sendable {
    public let weekId: String
    public let serverTime: Date
    public let items: [GroceryItem]

    enum CodingKeys: String, CodingKey {
        case weekId
        case serverTime
        case items
    }
}

/// M28 — pantry item (always-in-stock ingredient with optional
/// recurring auto-add to weekly grocery).
public struct PantryItem: Codable, Identifiable, Hashable, Sendable {
    public let pantryItemId: String
    public let stapleName: String
    public let normalizedName: String
    public let notes: String
    public let isActive: Bool
    public let typicalQuantity: Double?
    public let typicalUnit: String
    public let recurringQuantity: Double?
    public let recurringUnit: String
    /// `none` | `weekly` | `biweekly` | `monthly`. `none` = pure
    /// staple (filtered from meal grocery; never auto-added).
    public let recurringCadence: String
    public let category: String
    public let lastAppliedAt: Date?
    public let updatedAt: Date

    public var id: String { pantryItemId }

    public var hasRecurring: Bool { recurringCadence != "none" }

    public init(
        pantryItemId: String,
        stapleName: String,
        normalizedName: String,
        notes: String = "",
        isActive: Bool = true,
        typicalQuantity: Double? = nil,
        typicalUnit: String = "",
        recurringQuantity: Double? = nil,
        recurringUnit: String = "",
        recurringCadence: String = "none",
        category: String = "",
        lastAppliedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.pantryItemId = pantryItemId
        self.stapleName = stapleName
        self.normalizedName = normalizedName
        self.notes = notes
        self.isActive = isActive
        self.typicalQuantity = typicalQuantity
        self.typicalUnit = typicalUnit
        self.recurringQuantity = recurringQuantity
        self.recurringUnit = recurringUnit
        self.recurringCadence = recurringCadence
        self.category = category
        self.lastAppliedAt = lastAppliedAt
        self.updatedAt = updatedAt
    }
}

/// M26 Phase 3 — per-household shorthand alias.
public struct HouseholdTermAlias: Codable, Identifiable, Hashable, Sendable {
    public let aliasId: String
    public let term: String
    public let expansion: String
    public let notes: String
    public let updatedAt: Date

    public var id: String { aliasId }

    public init(
        aliasId: String,
        term: String,
        expansion: String,
        notes: String = "",
        updatedAt: Date = Date()
    ) {
        self.aliasId = aliasId
        self.term = term
        self.expansion = expansion
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

public struct WeekMealSide: Codable, Identifiable, Hashable, Sendable {
    public let sideId: String
    public let weekMealId: String
    public let recipeId: String?
    public let recipeName: String?
    public let name: String
    public let notes: String
    public let sortOrder: Int
    public let updatedAt: Date

    public var id: String { sideId }

    public init(
        sideId: String,
        weekMealId: String,
        recipeId: String? = nil,
        recipeName: String? = nil,
        name: String,
        notes: String = "",
        sortOrder: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.sideId = sideId
        self.weekMealId = weekMealId
        self.recipeId = recipeId
        self.recipeName = recipeName
        self.name = name
        self.notes = notes
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
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
    public let sides: [WeekMealSide]
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
        case sides
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
        sides = try container.decodeIfPresent([WeekMealSide].self, forKey: .sides) ?? []
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

    /// Memberwise initializer used by `replacingGroceryItems(_:)` to
    /// build a new snapshot with mutated grocery items. Internal-ish
    /// helper — every `let` field is reproduced verbatim except the
    /// one being replaced.
    public init(
        weekId: String,
        weekStart: Date,
        weekEnd: Date,
        status: String,
        notes: String,
        readyForAiAt: Date?,
        approvedAt: Date?,
        pricedAt: Date?,
        updatedAt: Date,
        stagedChangeCount: Int,
        feedbackCount: Int,
        exportCount: Int,
        meals: [WeekMeal],
        groceryItems: [GroceryItem],
        nutritionTotals: [DailyNutrition],
        weeklyTotals: MacroBreakdown?
    ) {
        self.weekId = weekId
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.status = status
        self.notes = notes
        self.readyForAiAt = readyForAiAt
        self.approvedAt = approvedAt
        self.pricedAt = pricedAt
        self.updatedAt = updatedAt
        self.stagedChangeCount = stagedChangeCount
        self.feedbackCount = feedbackCount
        self.exportCount = exportCount
        self.meals = meals
        self.groceryItems = groceryItems
        self.nutritionTotals = nutritionTotals
        self.weeklyTotals = weeklyTotals
    }

    /// Returns a copy with `groceryItems` swapped. Used by AppState's
    /// optimistic mutation helpers to keep the local snapshot in sync
    /// with server PATCH responses without re-pulling the entire week.
    public func replacingGroceryItems(_ items: [GroceryItem]) -> WeekSnapshot {
        WeekSnapshot(
            weekId: weekId,
            weekStart: weekStart,
            weekEnd: weekEnd,
            status: status,
            notes: notes,
            readyForAiAt: readyForAiAt,
            approvedAt: approvedAt,
            pricedAt: pricedAt,
            updatedAt: updatedAt,
            stagedChangeCount: stagedChangeCount,
            feedbackCount: feedbackCount,
            exportCount: exportCount,
            meals: meals,
            groceryItems: items,
            nutritionTotals: nutritionTotals,
            weeklyTotals: weeklyTotals
        )
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
