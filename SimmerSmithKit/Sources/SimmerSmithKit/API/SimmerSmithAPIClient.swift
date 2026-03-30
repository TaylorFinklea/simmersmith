import Foundation

public enum SimmerSmithAPIError: LocalizedError {
    case missingServerURL
    case invalidResponse
    case unauthorized
    case server(String)

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
        }
    }
}

private struct APIErrorResponse: Decodable {
    let detail: String
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

private struct RecipeVariationDraftBody: Encodable {
    let goal: String
}

private struct RecipeSuggestionDraftBody: Encodable {
    let goal: String
}

private struct RecipeCompanionDraftBody: Encodable {
    let focus: String
}

private struct AssistantThreadCreateBody: Encodable {
    let title: String
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

    public func fetchBaseIngredients(query: String = "", limit: Int = 20) async throws -> [BaseIngredient] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await request(path: "/api/ingredients?q=\(encodedQuery)&limit=\(limit)")
    }

    public func fetchIngredientVariations(baseIngredientID: String) async throws -> [IngredientVariation] {
        try await request(path: "/api/ingredients/\(baseIngredientID)/variations")
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

    public func createAssistantThread(title: String = "") async throws -> AssistantThreadSummary {
        try await request(
            path: "/api/assistant/threads",
            method: "POST",
            body: AssistantThreadCreateBody(title: title)
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
        intent: String = "general"
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
                    intent: intent
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
            Task {
                do {
                    var currentEvent = ""
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
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
                } catch {
                    continuation.finish(throwing: error)
                }
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
        request.timeoutInterval = 20
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
