import Foundation

// SP-C voice week-planning — the pure decision table for WHERE each layer runs, given the
// runtime inputs. Kept host-testable (no FoundationModels): the app maps
// SystemLanguageModel.default.availability → ParseAvailability and the speech asset state →
// Bool, then calls plan(...). Deployment target is iOS 26, so there is NO OS-version gate —
// this is purely runtime readiness.

/// Mirrors SystemLanguageModel availability without importing FoundationModels.
public enum ParseAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible          // hardware can't run Apple Intelligence
    case appleIntelligenceNotEnabled // user hasn't turned it on
    case modelNotReady              // assets still downloading
}

/// Where the transcript → ParsedWeeklyPlan parse runs.
public enum ParseSource: Equatable, Sendable {
    case onDevice    // FoundationModels
    case cloud       // BYO key, one-shot structured generate
    case unavailable // neither path — show the "set up AI" CTA
}

/// Which speech engine transcribes.
public enum TranscribeEngine: Equatable, Sendable {
    case speechTranscriber // iOS 26 on-device streaming (asset installed)
    case sfSpeech          // the shipping SFSpeechRecognizer fallback
}

public struct VoicePlanningPlan: Equatable, Sendable {
    public let parseSource: ParseSource
    public let transcribeEngine: TranscribeEngine
    /// True when SOME parse path exists; false → the entry should show the set-up-AI CTA.
    public var canParse: Bool { parseSource != .unavailable }
}

public enum VoicePlanningAvailability {
    /// Decide the parse source + transcribe engine. Never dead-ends silently: an ineligible
    /// device with no cloud key yields `.unavailable` so the caller can show a clear CTA
    /// rather than a broken button.
    public static func plan(
        parse: ParseAvailability,
        transcriberAssetInstalled: Bool,
        hasCloudKey: Bool
    ) -> VoicePlanningPlan {
        let source: ParseSource
        switch parse {
        case .available:
            source = .onDevice
        case .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady:
            source = hasCloudKey ? .cloud : .unavailable
        }
        let engine: TranscribeEngine = transcriberAssetInstalled ? .speechTranscriber : .sfSpeech
        return VoicePlanningPlan(parseSource: source, transcribeEngine: engine)
    }
}
