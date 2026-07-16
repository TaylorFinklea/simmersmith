#if canImport(FoundationModels)
import BallastCore
import Foundation
import FoundationModels

@Generable(description: "One meal explicitly stated by the user, with a literal evidence span from the input")
struct GuidedFMMealEntry: Equatable {
    let day: String
    let slot: String
    let rawDish: String
    let intent: String
    let evidence: String

    func toWireEntry() -> WeeklyPlanWireEntry {
        WeeklyPlanWireEntry(
            day: day,
            slot: slot,
            rawDish: rawDish,
            intent: intent,
            evidence: evidence
        )
    }
}

@Generable(description: "Only meals explicitly stated by the user, or an empty list when none were stated")
struct GuidedFMWeeklyPlan: Equatable {
    let entries: [GuidedFMMealEntry]

    func toWirePayload() -> WeeklyPlanWirePayload {
        WeeklyPlanWirePayload(entries: entries.map { $0.toWireEntry() })
    }
}

public struct GuidedFMParseProvider: LanguageProvider {
    public let identity: ProviderIdentity

    public init(
        identity: ProviderIdentity = ProviderIdentity(
            name: "foundation-models-guided-voice-parse",
            privacy: .onDevice,
            capabilities: [.guidedGeneration]
        )
    ) {
        self.identity = identity
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw BallastError.unavailable(reason: Self.mapReason(reason))
        }

        let session = LanguageModelSession(instructions: request.instructions ?? Self.extractionInstructions)
        do {
            let response = try await session.respond(
                to: request.prompt,
                generating: GuidedFMWeeklyPlan.self,
                options: Self.mapOptions(request.options)
            )
            return GenerationResult(
                text: try Self.canonicalJSON(from: response.content),
                usage: .zero,
                provider: identity
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapError(error)
        } catch let error as BallastError {
            throw error
        } catch {
            throw BallastError.providerFailed(
                providerName: identity.name,
                underlying: String(describing: error)
            )
        }
    }

    public static let extractionInstructions = """
    You EXTRACT meals from the user's text — you do NOT plan or complete a week. Output exactly \
    one entry per meal the user explicitly states, and nothing else. If they mention one meal, \
    output exactly one entry; if they mention none, output an empty list. Use the day exactly as \
    said (Monday through Sunday, today, tomorrow, or tonight), the slot (breakfast, lunch, or \
    dinner), and put the dish exactly as spoken into rawDish. Set intent to eatOut for ordering \
    out, restaurants, or takeout; leftovers for leftovers; skip to skip a meal; otherwise recipe. \
    For every entry, copy a non-empty evidence span literally from the user's text that supports \
    that entry. Never invent or paraphrase evidence.
    """

    static func canonicalJSON(from value: GuidedFMWeeklyPlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value.toWirePayload())
        guard let text = String(data: data, encoding: .utf8) else {
            throw BallastError.providerFailed(
                providerName: "foundation-models-guided-voice-parse",
                underlying: "canonical JSON was not UTF-8"
            )
        }
        return text
    }

    static func mapReason(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> UnavailableReason {
        switch reason {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .notEnabled
        case .modelNotReady: .modelNotReady
        @unknown default: .unknown
        }
    }

    static func mapError(_ error: LanguageModelSession.GenerationError) -> BallastError {
        switch error {
        case .exceededContextWindowSize:
            .contextSizeExceeded(contextSize: nil, tokenCount: nil)
        case .assetsUnavailable:
            .unavailable(reason: .modelNotReady)
        case .guardrailViolation:
            .guardrailViolation
        case .unsupportedGuide:
            .unsupportedCapability(.guidedGeneration)
        case .decodingFailure:
            .parsing(raw: "", detail: error.localizedDescription)
        case .rateLimited:
            .rateLimited(resetDate: nil)
        case .refusal(let refusal, _):
            .refusal(explanation: String(describing: refusal))
        case .unsupportedLanguageOrLocale, .concurrentRequests:
            .providerFailed(
                providerName: "foundation-models-guided-voice-parse",
                underlying: error.localizedDescription
            )
        @unknown default:
            .providerFailed(
                providerName: "foundation-models-guided-voice-parse",
                underlying: error.localizedDescription
            )
        }
    }

    static func mapOptions(
        _ options: BallastCore.GenerationOptions
    ) -> FoundationModels.GenerationOptions {
        FoundationModels.GenerationOptions(
            temperature: options.temperature,
            maximumResponseTokens: options.maxOutputTokens
        )
    }
}
#endif
