import Foundation

public enum SimmerSmithAPIError: LocalizedError {
    case missingServerURL
    case invalidResponse
    case unauthorized
    case notFound
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
        case .notFound:
            return "Not found."
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

/// URLSessionDataDelegate that parses SSE frames as bytes arrive. Used by
/// `streamAssistantResponse` — URLSession.bytes(for:) buffers HTTP/2 DATA
/// frames client-side so deltas bunch up, but didReceive fires as each TLS
/// record lands. Parsing incrementally from a rolling Data buffer and
/// yielding complete frames into the AsyncThrowingStream continuation
/// gives true streaming.
final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<AssistantStreamEnvelope, Error>.Continuation
    // Holds incomplete text between `didReceive` calls. Parsed down into
    // lines on every chunk; unfinished lines stay in the buffer.
    private var pending = Data()
    private var currentEvent = ""
    private var dataLines: [String] = []
    fileprivate weak var task: URLSessionDataTask?

    init(continuation: AsyncThrowingStream<AssistantStreamEnvelope, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: SimmerSmithAPIError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        if !(200..<300).contains(http.statusCode) {
            let error: SimmerSmithAPIError = http.statusCode == 401
                ? .unauthorized
                : .server("HTTP \(http.statusCode)")
            continuation.finish(throwing: error)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        pending.append(data)
        // Split on \n. Keep any trailing partial line in `pending`.
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
            pending.removeSubrange(pending.startIndex...newlineIndex)
            // Strip optional trailing \r for CRLF tolerance.
            let trimmed: Data
            if lineData.last == 0x0D {
                trimmed = lineData.subdata(in: lineData.startIndex..<(lineData.endIndex - 1))
            } else {
                trimmed = lineData
            }
            let line = String(data: trimmed, encoding: .utf8) ?? ""
            if line.isEmpty {
                if !currentEvent.isEmpty {
                    let payload = Data(dataLines.joined(separator: "\n").utf8)
                    continuation.yield(AssistantStreamEnvelope(event: currentEvent, data: payload))
                }
                currentEvent = ""
                dataLines = []
            } else if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                dataLines.append(String(line.dropFirst(6)))
            }
            // Lines starting with ":" are SSE comments — ignore.
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let nsError = error as NSError?,
           nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            continuation.finish()
            return
        }
        if let error {
            continuation.finish(throwing: error)
            return
        }
        if !currentEvent.isEmpty {
            let payload = Data(dataLines.joined(separator: "\n").utf8)
            continuation.yield(AssistantStreamEnvelope(event: currentEvent, data: payload))
        }
        continuation.finish()
    }
}

public final class SimmerSmithAPIClient: @unchecked Sendable {
    private let settingsStore: ConnectionSettingsStore
    private let session: URLSession
    // Dedicated session for long-lived SSE connections. Kept separate from
    // `session` so unrelated requests (pull-to-refresh, autosave) can't
    // cancel the assistant stream via shared-task teardown.
    private let streamingSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        settingsStore: ConnectionSettingsStore = .shared,
        session: URLSession = .shared,
        streamingSession: URLSession? = nil,
        decoder: JSONDecoder = SimmerSmithJSONCoding.makeDecoder(),
        encoder: JSONEncoder = SimmerSmithJSONCoding.makeEncoder()
    ) {
        self.settingsStore = settingsStore
        self.session = session
        self.streamingSession = streamingSession ?? Self.makeStreamingSession()
        self.decoder = decoder
        self.encoder = encoder
    }

    private static func makeStreamingSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        // Hint the OS that this stream should be low-latency. Combined with
        // the URLSessionDataDelegate reader this keeps HTTP/2 DATA frame
        // delivery near-real-time instead of batched.
        config.networkServiceType = .responsiveData
        return URLSession(configuration: config)
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

    /// Fetch the raw bytes of a recipe's AI-generated header image.
    /// Returns the response body verbatim — caller is responsible for
    /// decoding via `UIImage(data:)`. Throws `notFound` when no image
    /// exists for the recipe (the route 404s in that case).
    public struct RecipeImageBackfillResult: Codable, Sendable {
        public let generated: Int
        public let failed: Int
        public let skipped: Int
    }

    /// Generate header images for every recipe missing one. Reuses
    /// the same OpenAI image-gen path as the on-create flow. Synchronous
    /// at the dogfooding scale we ship at — caller spins a progress
    /// indicator.
    public func backfillRecipeImages() async throws -> RecipeImageBackfillResult {
        struct EmptyBody: Encodable {}
        return try await request(
            path: "/api/recipes/ai/backfill-images",
            method: "POST",
            body: EmptyBody()
        )
    }

    // MARK: - Recipe memories (M15)

    public func fetchRecipeMemories(recipeID: String) async throws -> [RecipeMemory] {
        try await request(path: "/api/recipes/\(recipeID)/memories")
    }

    public func createRecipeMemory(recipeID: String, body: String) async throws -> RecipeMemory {
        struct Body: Encodable {
            let body: String
        }
        return try await request(
            path: "/api/recipes/\(recipeID)/memories",
            method: "POST",
            body: Body(body: body)
        )
    }

    public func deleteRecipeMemory(recipeID: String, memoryID: String) async throws {
        let request = try buildRequest(
            path: "/api/recipes/\(recipeID)/memories/\(memoryID)",
            method: "DELETE",
            requiresAuth: true,
            bodyData: nil
        )
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimmerSmithAPIError.invalidResponse
        }
        if http.statusCode == 404 {
            throw SimmerSmithAPIError.notFound
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SimmerSmithAPIError.invalidResponse
        }
    }

    public func fetchRecipeImageBytes(recipeID: String) async throws -> Data {
        let request = try buildRequest(
            path: "/api/recipes/\(recipeID)/image",
            method: "GET",
            requiresAuth: true,
            bodyData: nil
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimmerSmithAPIError.invalidResponse
        }
        if http.statusCode == 404 {
            throw SimmerSmithAPIError.notFound
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SimmerSmithAPIError.invalidResponse
        }
        return data
    }

    public func importRecipe(fromURL url: String) async throws -> RecipeDraft {
        try await request(path: "/api/recipes/import-from-url", method: "POST", body: RecipeImportBody(url: url))
    }

    public func searchRecipeOnWeb(query: String) async throws -> RecipeDraft {
        struct Body: Encodable {
            let query: String
        }
        return try await request(
            path: "/api/recipes/ai/web-search",
            method: "POST",
            body: Body(query: query)
        )
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

        // URLSession.bytes(for:) buffers aggressively on HTTP/2 connections
        // (verified against production: curl sees each delta at 100ms
        // boundaries, iOS AsyncBytes reveals them all at once at the end).
        // Use a URLSessionDataDelegate instead — didReceive fires as each
        // TLS record arrives, so we get near-real-time SSE delivery.
        return AsyncThrowingStream { continuation in
            let delegate = SSEStreamDelegate(continuation: continuation)
            let session = URLSession(
                configuration: streamingSession.configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = session.dataTask(with: request)
            delegate.task = task
            task.resume()
            continuation.onTermination = { _ in
                task.cancel()
                // Finish the delegate's session so it doesn't leak across
                // cancellation. The delegate holds a strong ref via
                // `delegate:` on init; invalidateAndCancel breaks it.
                session.invalidateAndCancel()
            }
        }
    }

    public func saveRecipe(_ recipe: RecipeDraft) async throws -> RecipeSummary {
        try await request(path: "/api/recipes", method: "POST", body: recipe)
    }

    public func suggestIngredientSubstitutions(
        recipeID: String,
        ingredientID: String,
        hint: String = ""
    ) async throws -> IngredientSubstituteResponse {
        struct Body: Encodable {
            let ingredientId: String
            let hint: String
        }
        return try await request(
            path: "/api/recipes/\(recipeID)/ai/substitute",
            method: "POST",
            body: Body(ingredientId: ingredientID, hint: hint)
        )
    }

    // MARK: - Vision (M11)

    public func identifyIngredient(
        imageData: Data,
        mimeType: String = "image/jpeg"
    ) async throws -> IngredientIdentification {
        struct Body: Encodable {
            let imageBase64: String
            let mimeType: String
        }
        return try await request(
            path: "/api/vision/identify-ingredient",
            method: "POST",
            body: Body(
                imageBase64: imageData.base64EncodedString(),
                mimeType: mimeType
            )
        )
    }

    public func fetchSeasonalProduce() async throws -> [InSeasonItem] {
        try await request(path: "/api/seasonal/produce")
    }

    public func suggestPairings(recipeID: String) async throws -> RecipePairings {
        try await request(
            path: "/api/recipes/\(recipeID)/pairings",
            method: "POST"
        )
    }

    public func cookCheck(
        recipeID: String,
        stepNumber: Int,
        imageData: Data,
        mimeType: String = "image/jpeg"
    ) async throws -> CookCheckResult {
        struct Body: Encodable {
            let imageBase64: String
            let mimeType: String
            let stepNumber: Int
        }
        return try await request(
            path: "/api/recipes/\(recipeID)/cook-check",
            method: "POST",
            body: Body(
                imageBase64: imageData.base64EncodedString(),
                mimeType: mimeType,
                stepNumber: stepNumber
            )
        )
    }

    public func lookupProductByUPC(
        upc: String,
        locationID: String
    ) async throws -> ProductLookup {
        struct Body: Encodable {
            let upc: String
            let locationId: String
        }
        return try await request(
            path: "/api/products/lookup-upc",
            method: "POST",
            body: Body(upc: upc, locationId: locationID)
        )
    }

    // MARK: - Event Plans (M10)

    public func fetchGuests(includeInactive: Bool = false) async throws -> [Guest] {
        let query = includeInactive ? "?include_inactive=true" : ""
        return try await request(path: "/api/guests\(query)")
    }

    public func upsertGuest(
        guestID: String? = nil,
        name: String,
        relationshipLabel: String = "",
        dietaryNotes: String = "",
        allergies: String = "",
        ageGroup: String = "adult",
        active: Bool = true
    ) async throws -> Guest {
        struct Body: Encodable {
            let guestId: String?
            let name: String
            let relationshipLabel: String
            let dietaryNotes: String
            let allergies: String
            let ageGroup: String
            let active: Bool
        }
        return try await request(
            path: "/api/guests",
            method: "POST",
            body: Body(
                guestId: guestID,
                name: name,
                relationshipLabel: relationshipLabel,
                dietaryNotes: dietaryNotes,
                allergies: allergies,
                ageGroup: ageGroup,
                active: active
            )
        )
    }

    public func deleteGuest(guestID: String) async throws {
        let _: EmptyResponse = try await request(path: "/api/guests/\(guestID)", method: "DELETE")
    }

    public func fetchEvents() async throws -> [EventSummary] {
        try await request(path: "/api/events")
    }

    public func fetchEvent(eventID: String) async throws -> Event {
        try await request(path: "/api/events/\(eventID)")
    }

    public func createEvent(
        name: String,
        eventDate: Date? = nil,
        occasion: String = "other",
        attendeeCount: Int = 0,
        notes: String = "",
        attendees: [(guestID: String, plusOnes: Int)] = []
    ) async throws -> Event {
        struct AttendeeBody: Encodable {
            let guestId: String
            let plusOnes: Int
        }
        struct Body: Encodable {
            let name: String
            // String, not Date — Pydantic's `date` field rejects ISO
            // datetimes that carry a non-zero time component, which is
            // what the shared encoder produces. We send "YYYY-MM-DD".
            let eventDate: String?
            let occasion: String
            let attendeeCount: Int
            let notes: String
            let attendees: [AttendeeBody]
        }
        return try await request(
            path: "/api/events",
            method: "POST",
            body: Body(
                name: name,
                eventDate: Self.dateOnlyString(eventDate),
                occasion: occasion,
                attendeeCount: attendeeCount,
                notes: notes,
                attendees: attendees.map { AttendeeBody(guestId: $0.guestID, plusOnes: $0.plusOnes) }
            )
        )
    }

    /// Formats a Swift Date as the calendar-day string "YYYY-MM-DD" using
    /// the user's local calendar — matches the Pydantic `date` type the
    /// backend uses for event_date and similar fields. Returns nil for
    /// nil input so the JSON payload sends `null` instead of an empty
    /// string.
    static func dateOnlyString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    public func updateEvent(
        eventID: String,
        name: String,
        eventDate: Date?,
        occasion: String,
        attendeeCount: Int,
        notes: String,
        status: String,
        attendees: [(guestID: String, plusOnes: Int)]
    ) async throws -> Event {
        struct AttendeeBody: Encodable {
            let guestId: String
            let plusOnes: Int
        }
        struct Body: Encodable {
            let name: String
            let eventDate: String?
            let occasion: String
            let attendeeCount: Int
            let notes: String
            let status: String
            let attendees: [AttendeeBody]
        }
        return try await request(
            path: "/api/events/\(eventID)",
            method: "PATCH",
            body: Body(
                name: name,
                eventDate: Self.dateOnlyString(eventDate),
                occasion: occasion,
                attendeeCount: attendeeCount,
                notes: notes,
                status: status,
                attendees: attendees.map { AttendeeBody(guestId: $0.guestID, plusOnes: $0.plusOnes) }
            )
        )
    }

    public func deleteEvent(eventID: String) async throws {
        let _: EmptyResponse = try await request(path: "/api/events/\(eventID)", method: "DELETE")
    }

    public func addEventMeal(
        eventID: String,
        role: String,
        recipeName: String,
        recipeID: String? = nil,
        servings: Double? = nil,
        notes: String = "",
        assignedGuestID: String? = nil
    ) async throws -> Event {
        struct Body: Encodable {
            let role: String
            let recipeId: String?
            let recipeName: String
            let servings: Double?
            let notes: String
            let assignedGuestId: String?
        }
        return try await request(
            path: "/api/events/\(eventID)/meals",
            method: "POST",
            body: Body(
                role: role,
                recipeId: recipeID,
                recipeName: recipeName,
                servings: servings,
                notes: notes,
                assignedGuestId: assignedGuestID
            )
        )
    }

    public func updateEventMeal(
        eventID: String,
        mealID: String,
        role: String? = nil,
        recipeID: String? = nil,
        recipeName: String? = nil,
        servings: Double? = nil,
        notes: String? = nil,
        assignedGuestID: String? = nil,
        clearAssignee: Bool = false
    ) async throws -> Event {
        struct Body: Encodable {
            let role: String?
            let recipeId: String?
            let recipeName: String?
            let servings: Double?
            let notes: String?
            let assignedGuestId: String?
            let clearAssignee: Bool
        }
        return try await request(
            path: "/api/events/\(eventID)/meals/\(mealID)",
            method: "PATCH",
            body: Body(
                role: role,
                recipeId: recipeID,
                recipeName: recipeName,
                servings: servings,
                notes: notes,
                assignedGuestId: assignedGuestID,
                clearAssignee: clearAssignee
            )
        )
    }

    public func deleteEventMeal(eventID: String, mealID: String) async throws -> Event {
        try await request(
            path: "/api/events/\(eventID)/meals/\(mealID)",
            method: "DELETE"
        )
    }

    public func generateEventMenu(
        eventID: String,
        prompt: String = "",
        roles: [String] = []
    ) async throws -> EventMenuResponse {
        struct Body: Encodable {
            let prompt: String
            let roles: [String]
        }
        return try await request(
            path: "/api/events/\(eventID)/ai/menu",
            method: "POST",
            body: Body(prompt: prompt, roles: roles)
        )
    }

    public func refreshEventGrocery(eventID: String) async throws -> Event {
        try await request(
            path: "/api/events/\(eventID)/grocery/refresh",
            method: "POST",
            body: EmptyBody()
        )
    }

    public func mergeEventGroceryIntoWeek(eventID: String, weekID: String) async throws -> Event {
        struct Body: Encodable { let weekId: String }
        return try await request(
            path: "/api/events/\(eventID)/grocery/merge",
            method: "POST",
            body: Body(weekId: weekID)
        )
    }

    public func unmergeEventGroceryFromWeek(eventID: String, weekID: String) async throws -> Event {
        try await request(
            path: "/api/events/\(eventID)/grocery/merge?week_id=\(weekID)",
            method: "DELETE"
        )
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
