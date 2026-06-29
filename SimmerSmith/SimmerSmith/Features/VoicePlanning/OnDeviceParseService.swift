import Foundation
import SimmerSmithKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// SP-C voice week-planning — layer 2 (on-device parse). Turns a transcript into a
/// ParsedWeeklyPlan using Foundation Models constrained decoding. The recipe library is NOT
/// in the prompt (4096-token window); resolution to recipe IDs is a separate pure layer.
/// Throws to signal the coordinator to fall back to cloud — the degradation policy lives there.
enum OnDeviceParseService {

    enum ParseError: LocalizedError {
        case unavailable
        case modelError(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "On-device planning isn't available on this device."
            case .modelError(let detail): return "On-device planning failed: \(detail)"
            }
        }
    }

    /// Current on-device parse availability, mapped to the package's UI-facing enum.
    static func availability() -> ParseAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .deviceNotEligible
            }
        }
        #else
        return .deviceNotEligible
        #endif
    }

    /// Parse a transcript on-device. Pre-condition: availability() == .available.
    static func parse(transcript: String) async throws -> ParsedWeeklyPlan {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: instructions)
        do {
            // The verified String overload of respond(to:generating:) — no Prompt wrapper needed.
            let response = try await session.respond(to: transcript, generating: GenerableWeeklyPlan.self)
            return response.content.toParsed()
        } catch let error as LanguageModelSession.GenerationError {
            // exceededContextWindowSize / decodingFailure / guardrailViolation / refusal /
            // assetsUnavailable / unsupportedGuide / rateLimited … → caller falls back to cloud.
            throw ParseError.modelError(String(describing: error))
        } catch {
            throw ParseError.modelError(error.localizedDescription)
        }
        #else
        throw ParseError.unavailable
        #endif
    }

    private static let instructions = """
    You EXTRACT meals from the user's text — you do NOT plan or complete a week. Output exactly \
    one entry per meal the user EXPLICITLY states, and nothing else: never add days, meals, or \
    slots they did not say. If they mention one meal, output exactly one entry; if they mention \
    none, output an empty list. Use the day exactly as said ("Monday"…"Sunday", or \
    "today"/"tomorrow"/"tonight"), the slot ("breakfast", "lunch", or "dinner"), and put the \
    dish exactly as spoken into rawDish. Set intent to "eatOut" for ordering out / restaurants \
    / takeout / pizza, "leftovers" for leftovers, "skip" to skip a meal, otherwise "recipe".
    For example, "Tuna for lunch on Tuesday" gives EXACTLY one entry: day "Tuesday", slot \
    "lunch", rawDish "tuna", intent "recipe" — and nothing else.
    """
}
