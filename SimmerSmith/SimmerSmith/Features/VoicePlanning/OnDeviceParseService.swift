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
    Extract a weekly meal plan from the user's spoken request. Output one entry per meal the \
    user assigns to a day. Use the day exactly as said ("Monday"…"Sunday", or \
    "today"/"tomorrow"/"tonight") and the slot ("breakfast", "lunch", or "dinner"). Put the \
    dish exactly as spoken into rawDish. Set intent to "eatOut" for ordering out / restaurants \
    / takeout / pizza delivery, "leftovers" for leftovers, "skip" to leave a meal unplanned, \
    otherwise "recipe". Do not invent meals the user did not mention.
    """
}
