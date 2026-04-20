import Foundation

public enum SimmerSmithAPIError: LocalizedError {
    case missingServerURL
    case invalidResponse
    case unauthorized
    case server(String)
    /// HTTP 402 from the freemium gate. `action` tells the client which
    /// flow hit the limit (e.g. "ai_generate") so the paywall copy can
    /// explain what just got blocked.
    case usageLimitReached(action: String, limit: Int, used: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingServerURL:
            return "Enter a SimmerSmith server URL first."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .unauthorized:
            return "The server rejected the current bearer token."
        case .server(let message):
            return message
        case .usageLimitReached(_, _, _, let message):
            return message
        }
    }
}

/// FastAPI returns validation errors as `{"detail": [{"loc": [...], "msg": "...", ...}]}`
/// and generic exceptions as `{"detail": "message"}`. This decoder handles both
/// (plus an arbitrary JSON object for forward compatibility) so we surface the
/// real reason to the user instead of falling through to a generic
/// "invalid response" error.
private struct APIErrorResponse: Decodable {
    let detail: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringDetail = try? container.decode(String.self, forKey: .detail) {
            self.detail = stringDetail
            return
        }
        if let errors = try? container.decode([ValidationErrorItem].self, forKey: .detail) {
            self.detail = errors.map { $0.displayText }.joined(separator: "; ")
            return
        }
        if let object = try? container.decode([String: JSONRaw].self, forKey: .detail),
           let message = object["message"]?.stringValue {
            self.detail = message
            return
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized error detail shape"
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case detail
    }

    private struct ValidationErrorItem: Decodable {
        let loc: [JSONRaw]?
        let msg: String?
        let type: String?

        var displayText: String {
            let field = (loc ?? []).compactMap { $0.stringValue }.joined(separator: ".")
            let message = msg ?? type ?? "Invalid field"
            return field.isEmpty ? message : "\(field): \(message)"
        }
    }

    private enum JSONRaw: Decodable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            if let d = try? c.decode(Double.self) { self = .double(d); return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            self = .null
        }

        var stringValue: String? {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return String(b)
            case .null: return nil
            }
        }
    }
}

private struct UsageLimitResponse: Decodable {
    let detail: DetailBody

    struct DetailBody: Decodable {
        let message: String
        let action: String
        let limit: Int
        let used: Int
    }
}

private struct RecipeImportBody: Encodable {
    let url: String
}

private struct RecipeTextImportBody: Encodable {
    let text: String
    let title: String
    let source: String
    let sourceLabel: String
    let sourceUrl: String
}

private struct GenerateWeekBody: Encodable {
    let prompt: String
}

private struct RecipeVariationDraftBody: Encodable {
    let goal: String
}

private struct RecipeSuggestionDraftBody: Encodable {
    let goal: String
}

private struct RecipeCompanionDraftBody: Encodable {
    let focus: String
}

private struct TokenExchangeBody: Encodable {
    let identityToken: String
}

private struct FetchPricingBody: Encodable {
    let locationId: String
}

private struct AssistantThreadCreateBody: Encodable {
    let title: String
    let threadKind: String
    let linkedWeekId: String?
}

private struct ProfileUpdateBody: Encodable {
    let settings: [String: String]
    let staples: [Staple]?
}

private struct ManagedListItemBody: Encodable {
    let name: String
}

private struct IngredientNutritionMatchBody: Encodable {
    let ingredientName: String
    let normalizedName: String?
    let nutritionItemId: String
}

private struct IngredientResolveBody: Encodable {
    let ingredientName: String
    let normalizedName: String?
    let quantity: Double?
    let unit: String
    let prep: String
    let category: String
    let notes: String
}

private struct IngredientPreferenceBody: Encodable {
    let preferenceId: String?
    let baseIngredientId: String
    let preferredVariationId: String?
    let preferredBrand: String
    let choiceMode: String
    let active: Bool
    let notes: String
}

private struct BaseIngredientBody: Encodable {
    let baseIngredientId: String?
    let name: String
    let normalizedName: String?
    let category: String
    let defaultUnit: String
    let notes: String
    let sourceName: String
    let sourceRecordId: String
    let sourceURL: String
    let provisional: Bool
    let active: Bool
    let nutritionReferenceAmount: Double?
    let nutritionReferenceUnit: String
    let calories: Double?
}

private struct IngredientVariationBody: Encodable {
    let ingredientVariationId: String?
    let name: String
    let normalizedName: String?
    let brand: String
    let upc: String
    let packageSizeAmount: Double?
    let packageSizeUnit: String
    let countPerPackage: Double?
    let productUrl: String
    let retailerHint: String
    let notes: String
    let sourceName: String
    let sourceRecordId: String
    let sourceURL: String
    let active: Bool
    let nutritionReferenceAmount: Double?
    let nutritionReferenceUnit: String
    let calories: Double?
}

private struct IngredientMergeBody: Encodable {
    let targetId: String
}

public final class SimmerSmithAPIClient: @unchecked Sendable {
    private let settingsStore: ConnectionSettingsStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        settingsStore: ConnectionSettingsStore = .shared,
        session: URLSession = .shared,
        decoder: JSONDecoder = SimmerSmithJSONCoding.makeDecoder(),
        encoder: JSONEncoder = SimmerSmithJSONCoding.makeEncoder()
    ) {
        self.settingsStore = settingsStore
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    public func fetchHealth() async throws -> HealthResponse {
        try await request(path: "/api/health", requiresAuth: false)
    }

    public func signInWithApple(identityToken: String) async throws -> AuthTokenResponse {
        try await request(
            path: "/api/auth/apple",
            method: "POST",
            requiresAuth: false,
            body: TokenExchangeBody(identityToken: identityToken)
        )
    }

    public func signInWithGoogle(identityToken: String) async throws -> AuthTokenResponse {
        try await request(
            path: "/api/auth/google",
            method: "POST",
            requiresAuth: false,
            body: TokenExchangeBody(identityToken: identityToken)
        )
    }

    public func fetchProviderModels(providerID: String) async throws -> AIProviderModels {
        try await request(path: "/api/ai/providers/\(providerID)/models")
    }

    public func fetchProfile() async throws -> ProfileSnapshot {
        try await request(path: "/api/profile")
    }

    public func updateProfile(
        settings: [String: String],
        staples: [Staple]? = nil
    ) async throws -> ProfileSnapshot {
        try await request(
            path: "/api/profile",
            method: "PUT",
            body: ProfileUpdateBody(settings: settings, staples: staples)
        )
    }

    public func fetchDietaryGoal() async throws -> DietaryGoal? {
        struct Wrapper: Decodable {
            let value: DietaryGoal?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() {
                    value = nil
                } else {
                    value = try container.decode(DietaryGoal.self)
                }
            }
        }
        let wrapped: Wrapper = try await request(path: "/api/profile/dietary-goal")
        return wrapped.value
    }

    public func saveDietaryGoal(_ goal: DietaryGoal) async throws -> DietaryGoal {
        try await request(path: "/api/profile/dietary-goal", method: "PUT", body: goal)
    }

    public func clearDietaryGoal() async throws {
        let _: EmptyResponse = try await request(path: "/api/profile/dietary-goal", method: "DELETE")
    }

    // MARK: - Subscriptions (StoreKit 2)

    public func verifySubscriptionTransaction(signedJWS: String) async throws -> SubscriptionStatus {
        struct Body: Encodable { let signedTransaction: String }
        return try await request(
            path: "/api/subscriptions/verify",
            method: "POST",
            body: Body(signedTransaction: signedJWS)
        )
    }

    public func fetchCurrentWeek() async throws -> WeekSnapshot? {
        try await request(path: "/api/weeks/current")
    }

    public func fetchWeek(weekID: String) async throws -> WeekSnapshot {
        try await request(path: "/api/weeks/\(weekID)")
    }

    public func fetchWeekByStart(_ weekStart: Date) async throws -> WeekSnapshot? {
        try await request(path: "/api/weeks/by-start?week_start=\(Self.dayString(from: weekStart))")
    }

    public func fetchWeeks(limit: Int = 12) async throws -> [WeekSummary] {
        try await request(path: "/api/weeks?limit=\(limit)")
    }

    public func createWeek(weekStart: Date, notes: String = "") async throws -> WeekSnapshot {
        try await request(path: "/api/weeks", method: "POST", body: WeekCreateRequest(weekStart: weekStart, notes: notes))
    }

    public func updateWeekMeals(weekID: String, meals: [MealUpdateRequest]) async throws -> WeekSnapshot {
        try await request(path: "/api/weeks/\(weekID)/meals", method: "PUT", body: meals)
    }

    public func generateWeekPlan(weekID: String, prompt: String) async throws -> WeekSnapshot {
        try await request(path: "/api/weeks/\(weekID)/generate", method: "POST", body: GenerateWeekBody(prompt: prompt))
    }

    public func approveWeek(weekID: String) async throws -> WeekSnapshot {
        try await request(path: "/api/weeks/\(weekID)/approve", method: "POST", body: EmptyBody())
    }

    public func regenerateGrocery(weekID: String) async throws -> WeekSnapshot {
        try await request(path: "/api/weeks/\(weekID)/grocery/regenerate", method: "POST", body: EmptyBody())
    }

    public func rebalanceDay(weekID: String, mealDate: Date) async throws -> WeekSnapshot {
        struct Body: Encodable { let mealDate: String }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return try await request(
            path: "/api/weeks/\(weekID)/days/rebalance",
            method: "POST",
            body: Body(mealDate: formatter.string(from: mealDate))
        )
    }

    public func fetchRecipes(includeArchived: Bool = false) async throws -> [RecipeSummary] {
        let suffix = includeArchived ? "?include_archived=true" : ""
        return try await request(path: "/api/recipes\(suffix)")
    }

    public func fetchRecipeMetadata() async throws -> RecipeMetadata {
        try await request(path: "/api/recipes/metadata")
    }

    public func createManagedListItem(kind: String, name: String) async throws -> ManagedListItem {
        try await request(path: "/api/recipes/metadata/\(kind)", method: "POST", body: ManagedListItemBody(name: name))
    }

    public func estimateRecipeNutrition(_ recipe: RecipeDraft) async throws -> NutritionSummary {
        try await request(path: "/api/recipes/nutrition/estimate", method: "POST", body: recipe)
    }

    public func searchNutritionItems(query: String = "", limit: Int = 20) async throws -> [NutritionItem] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await request(path: "/api/recipes/nutrition/search?q=\(encodedQuery)&limit=\(limit)")
    }

    public func fetchBaseIngredients(
        query: String = "",
        limit: Int = 20,
        includeArchived: Bool = false,
        provisionalOnly: Bool = false,
        withPreferences: Bool = false,
        withVariations: Bool = false,
        includeProductLike: Bool = false
    ) async throws -> [BaseIngredient] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var path = "/api/ingredients?q=\(encodedQuery)&limit=\(limit)"
        if includeArchived {
            path += "&include_archived=true"
        }
        if provisionalOnly {
            path += "&provisional_only=true"
        }
        if withPreferences {
            path += "&with_preferences=true"
        }
        if withVariations {
            path += "&with_variations=true"
        }
        if includeProductLike {
            path += "&include_product_like=true"
        }
        return try await request(path: path)
    }

    public func fetchBaseIngredientDetail(baseIngredientID: String) async throws -> BaseIngredientDetail {
        try await request(path: "/api/ingredients/\(baseIngredientID)")
    }

    public func fetchIngredientVariations(baseIngredientID: String) async throws -> [IngredientVariation] {
        try await request(path: "/api/ingredients/\(baseIngredientID)/variations")
    }

    public func createBaseIngredient(
        name: String,
        normalizedName: String? = nil,
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
        calories: Double? = nil
    ) async throws -> BaseIngredient {
        try await request(
            path: "/api/ingredients",
            method: "POST",
            body: BaseIngredientBody(
                baseIngredientId: nil,
                name: name,
                normalizedName: normalizedName,
                category: category,
                defaultUnit: defaultUnit,
                notes: notes,
                sourceName: sourceName,
                sourceRecordId: sourceRecordId,
                sourceURL: sourceURL,
                provisional: provisional,
                active: active,
                nutritionReferenceAmount: nutritionReferenceAmount,
                nutritionReferenceUnit: nutritionReferenceUnit,
                calories: calories
            )
        )
    }

    public func updateBaseIngredient(
        baseIngredientID: String,
        name: String,
        normalizedName: String? = nil,
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
        calories: Double? = nil
    ) async throws -> BaseIngredient {
        try await request(
            path: "/api/ingredients",
            method: "POST",
            body: BaseIngredientBody(
                baseIngredientId: baseIngredientID,
                name: name,
                normalizedName: normalizedName,
                category: category,
                defaultUnit: defaultUnit,
                notes: notes,
                sourceName: sourceName,
                sourceRecordId: sourceRecordId,
                sourceURL: sourceURL,
                provisional: provisional,
                active: active,
                nutritionReferenceAmount: nutritionReferenceAmount,
                nutritionReferenceUnit: nutritionReferenceUnit,
                calories: calories
            )
        )
    }

    public func archiveBaseIngredient(baseIngredientID: String) async throws -> BaseIngredient {
        try await request(path: "/api/ingredients/\(baseIngredientID)/archive", method: "POST", body: EmptyBody())
    }

    public func mergeBaseIngredient(sourceID: String, targetID: String) async throws -> BaseIngredient {
        try await request(
            path: "/api/ingredients/\(sourceID)/merge",
            method: "POST",
            body: IngredientMergeBody(targetId: targetID)
        )
    }

    public func createIngredientVariation(
        baseIngredientID: String,
        name: String,
        normalizedName: String? = nil,
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
        calories: Double? = nil
    ) async throws -> IngredientVariation {
        try await request(
            path: "/api/ingredients/\(baseIngredientID)/variations",
            method: "POST",
            body: IngredientVariationBody(
                ingredientVariationId: nil,
                name: name,
                normalizedName: normalizedName,
                brand: brand,
                upc: upc,
                packageSizeAmount: packageSizeAmount,
                packageSizeUnit: packageSizeUnit,
                countPerPackage: countPerPackage,
                productUrl: productUrl,
                retailerHint: retailerHint,
                notes: notes,
                sourceName: sourceName,
                sourceRecordId: sourceRecordId,
                sourceURL: sourceURL,
                active: active,
                nutritionReferenceAmount: nutritionReferenceAmount,
                nutritionReferenceUnit: nutritionReferenceUnit,
                calories: calories
            )
        )
    }

    public func updateIngredientVariation(
        ingredientVariationID: String,
        baseIngredientID: String,
        name: String,
        normalizedName: String? = nil,
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
        calories: Double? = nil
    ) async throws -> IngredientVariation {
        try await request(
            path: "/api/ingredients/\(baseIngredientID)/variations",
            method: "POST",
            body: IngredientVariationBody(
                ingredientVariationId: ingredientVariationID,
                name: name,
                normalizedName: normalizedName,
                brand: brand,
                upc: upc,
                packageSizeAmount: packageSizeAmount,
                packageSizeUnit: packageSizeUnit,
                countPerPackage: countPerPackage,
                productUrl: productUrl,
                retailerHint: retailerHint,
                notes: notes,
                sourceName: sourceName,
                sourceRecordId: sourceRecordId,
                sourceURL: sourceURL,
                active: active,
                nutritionReferenceAmount: nutritionReferenceAmount,
                nutritionReferenceUnit: nutritionReferenceUnit,
                calories: calories
            )
        )
    }

    public func archiveIngredientVariation(ingredientVariationID: String) async throws -> IngredientVariation {
        try await request(
            path: "/api/ingredients/variations/\(ingredientVariationID)/archive",
            method: "POST",
            body: EmptyBody()
        )
    }

    public func mergeIngredientVariation(sourceID: String, targetID: String) async throws -> IngredientVariation {
        try await request(
            path: "/api/ingredients/variations/\(sourceID)/merge",
            method: "POST",
            body: IngredientMergeBody(targetId: targetID)
        )
    }

    public func fetchIngredientPreferences() async throws -> [IngredientPreference] {
        try await request(path: "/api/ingredient-preferences")
    }

    public func resolveIngredient(_ ingredient: RecipeIngredient) async throws -> IngredientResolution {
        try await request(
            path: "/api/ingredients/resolve",
            method: "POST",
            body: IngredientResolveBody(
                ingredientName: ingredient.ingredientName,
                normalizedName: ingredient.normalizedName,
                quantity: ingredient.quantity,
                unit: ingredient.unit,
                prep: ingredient.prep,
                category: ingredient.category,
                notes: ingredient.notes
            )
        )
    }

    public func upsertIngredientPreference(
        preferenceID: String? = nil,
        baseIngredientID: String,
        preferredVariationID: String? = nil,
        preferredBrand: String = "",
        choiceMode: String = "preferred",
        active: Bool = true,
        notes: String = ""
    ) async throws -> IngredientPreference {
        try await request(
            path: "/api/ingredient-preferences",
            method: "POST",
            body: IngredientPreferenceBody(
                preferenceId: preferenceID,
                baseIngredientId: baseIngredientID,
                preferredVariationId: preferredVariationID,
                preferredBrand: preferredBrand,
                choiceMode: choiceMode,
                active: active,
                notes: notes
            )
        )
    }

    public func saveIngredientNutritionMatch(
        ingredientName: String,
        normalizedName: String?,
        nutritionItemID: String
    ) async throws -> IngredientNutritionMatch {
        try await request(
            path: "/api/recipes/nutrition/matches",
            method: "POST",
            body: IngredientNutritionMatchBody(
                ingredientName: ingredientName,
                normalizedName: normalizedName,
                nutritionItemId: nutritionItemID
            )
        )
    }

    public func fetchRecipe(recipeID: String) async throws -> RecipeSummary {
        try await request(path: "/api/recipes/\(recipeID)")
    }

    public func importRecipe(fromURL url: String) async throws -> RecipeDraft {
        try await request(path: "/api/recipes/import-from-url", method: "POST", body: RecipeImportBody(url: url))
    }

    public func importRecipe(
        fromText text: String,
        title: String = "",
        source: String = "scan_import",
        sourceLabel: String = "",
        sourceURL: String = ""
    ) async throws -> RecipeDraft {
        try await request(
            path: "/api/recipes/import-from-text",
            method: "POST",
            body: RecipeTextImportBody(
                text: text,
                title: title,
                source: source,
                sourceLabel: sourceLabel,
                sourceUrl: sourceURL
            )
        )
    }

    public func importRecipe(
        fromHTML html: String,
        sourceURL: String,
        sourceLabel: String = ""
    ) async throws -> RecipeDraft {
        try await request(
            path: "/api/recipes/import-from-html",
            method: "POST",
            body: RecipeTextImportBody(
                text: html,
                title: "",
                source: "web_import",
                sourceLabel: sourceLabel,
                sourceUrl: sourceURL
            )
        )
    }

    public func generateRecipeVariationDraft(recipeID: String, goal: String) async throws -> RecipeAIDraft {
        try await request(
            path: "/api/recipes/\(recipeID)/ai/variation-draft",
            method: "POST",
            body: RecipeVariationDraftBody(goal: goal)
        )
    }

    public func generateRecipeSuggestionDraft(goal: String) async throws -> RecipeAIDraft {
        try await request(
            path: "/api/recipes/ai/suggestion-draft",
            method: "POST",
            body: RecipeSuggestionDraftBody(goal: goal)
        )
    }

    public func generateRecipeCompanionDrafts(
        recipeID: String,
        focus: String = "sides_and_sauces"
    ) async throws -> RecipeAIOptions {
        try await request(
            path: "/api/recipes/\(recipeID)/ai/companion-drafts",
            method: "POST",
            body: RecipeCompanionDraftBody(focus: focus)
        )
    }

    public func fetchAssistantThreads() async throws -> [AssistantThreadSummary] {
        try await request(path: "/api/assistant/threads")
    }

    public func createAssistantThread(
        title: String = "",
        threadKind: String = "chat",
        linkedWeekID: String? = nil
    ) async throws -> AssistantThreadSummary {
        try await request(
            path: "/api/assistant/threads",
            method: "POST",
            body: AssistantThreadCreateBody(
                title: title,
                threadKind: threadKind,
                linkedWeekId: linkedWeekID
            )
        )
    }

    public func fetchAssistantThread(threadID: String) async throws -> AssistantThread {
        try await request(path: "/api/assistant/threads/\(threadID)")
    }

    public func deleteAssistantThread(threadID: String) async throws {
        let _: EmptyResponse = try await request(path: "/api/assistant/threads/\(threadID)", method: "DELETE")
    }

    public func streamAssistantResponse(
        threadID: String,
        text: String,
        attachedRecipeID: String? = nil,
        attachedRecipeDraft: RecipeDraft? = nil,
        intent: String = "general",
        pageContext: AssistantPageContextPayload? = nil
    ) async throws -> AsyncThrowingStream<AssistantStreamEnvelope, Error> {
        let request = try buildRequest(
            path: "/api/assistant/threads/\(threadID)/respond",
            method: "POST",
            requiresAuth: true,
            bodyData: try encoder.encode(
                AssistantRespondRequestBody(
                    text: text,
                    attachedRecipeId: attachedRecipeID,
                    attachedRecipeDraft: attachedRecipeDraft,
                    intent: intent,
                    pageContext: pageContext
                )
            )
        )
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimmerSmithAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(contentsOf: [byte])
            }
            if http.statusCode == 401 {
                throw SimmerSmithAPIError.unauthorized
            }
            if let errorPayload = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw SimmerSmithAPIError.server(errorPayload.detail)
            }
            throw SimmerSmithAPIError.invalidResponse
        }

        return AsyncThrowingStream { continuation in
            // Capture the reader task so we can cancel it when the stream
            // consumer terminates early (e.g. the user navigates away from
            // the thread view mid-stream). Without this, the inner SSE
            // connection stays open writing deltas into a deallocated
            // thread context.
            let task = Task {
                do {
                    var currentEvent = ""
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            if !currentEvent.isEmpty {
                                let payload = Data(dataLines.joined(separator: "\n").utf8)
                                continuation.yield(AssistantStreamEnvelope(event: currentEvent, data: payload))
                            }
                            currentEvent = ""
                            dataLines = []
                            continue
                        }
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            dataLines.append(String(line.dropFirst(6)))
                        }
                    }
                    if !currentEvent.isEmpty {
                        let payload = Data(dataLines.joined(separator: "\n").utf8)
                        continuation.yield(AssistantStreamEnvelope(event: currentEvent, data: payload))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func saveRecipe(_ recipe: RecipeDraft) async throws -> RecipeSummary {
        try await request(path: "/api/recipes", method: "POST", body: recipe)
    }

    public func archiveRecipe(recipeID: String) async throws -> RecipeSummary {
        try await request(path: "/api/recipes/\(recipeID)/archive", method: "POST", body: EmptyBody())
    }

    public func restoreRecipe(recipeID: String) async throws -> RecipeSummary {
        try await request(path: "/api/recipes/\(recipeID)/restore", method: "POST", body: EmptyBody())
    }

    public func deleteRecipe(recipeID: String) async throws {
        let _: EmptyResponse = try await request(path: "/api/recipes/\(recipeID)", method: "DELETE")
    }

    public func fetchWeekExports(weekID: String) async throws -> [ExportRun] {
        try await request(path: "/api/weeks/\(weekID)/exports")
    }

    public func submitFeedback(weekID: String, entries: [FeedbackEntryRequest]) async throws -> WeekFeedbackResponse {
        try await request(path: "/api/weeks/\(weekID)/feedback", method: "POST", body: entries)
    }

    // MARK: - Stores & Pricing

    public func searchStores(zipCode: String, radius: Int = 10) async throws -> [StoreLocation] {
        try await request(path: "/api/stores/search?zip_code=\(zipCode)&radius=\(radius)")
    }

    public func fetchPricing(weekID: String, locationID: String? = nil) async throws -> PricingResponse {
        try await request(
            path: "/api/weeks/\(weekID)/pricing/fetch",
            method: "POST",
            body: FetchPricingBody(locationId: locationID ?? "")
        )
    }

    public func getPricing(weekID: String) async throws -> PricingResponse {
        try await request(path: "/api/weeks/\(weekID)/pricing")
    }

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        requiresAuth: Bool = true
    ) async throws -> T {
        let request = try buildRequest(path: path, method: method, requiresAuth: requiresAuth, bodyData: nil)
        let (data, response) = try await session.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    private func request<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        requiresAuth: Bool = true,
        body: Body
    ) async throws -> T {
        let data = try encoder.encode(body)
        let request = try buildRequest(path: path, method: method, requiresAuth: requiresAuth, bodyData: data)
        let (responseData, response) = try await session.data(for: request)
        return try decodeResponse(data: responseData, response: response)
    }

    private func buildRequest(
        path: String,
        method: String,
        requiresAuth: Bool,
        bodyData: Data?
    ) throws -> URLRequest {
        let connection = settingsStore.load()
        let baseURLString = ConnectionSettingsStore.normalizeServerURL(connection.serverURLString)
        guard let baseURL = URL(string: baseURLString), !baseURLString.isEmpty else {
            throw SimmerSmithAPIError.missingServerURL
        }

        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresAuth {
            let token = connection.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw SimmerSmithAPIError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw SimmerSmithAPIError.unauthorized
            }
            if http.statusCode == 402,
               let payload = try? decoder.decode(UsageLimitResponse.self, from: data) {
                throw SimmerSmithAPIError.usageLimitReached(
                    action: payload.detail.action,
                    limit: payload.detail.limit,
                    used: payload.detail.used,
                    message: payload.detail.message
                )
            }
            if let errorPayload = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw SimmerSmithAPIError.server(errorPayload.detail)
            }
            throw SimmerSmithAPIError.invalidResponse
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        return try decoder.decode(T.self, from: data)
    }
}

private struct EmptyResponse: Decodable {}
private struct EmptyBody: Encodable {}

extension SimmerSmithAPIClient {
    private static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
