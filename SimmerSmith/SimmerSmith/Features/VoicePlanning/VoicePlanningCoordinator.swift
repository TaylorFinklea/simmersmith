import Foundation
import Observation
import SimmerSmithBallastAdapter
import SimmerSmithKit

/// SP-C voice week-planning — orchestrates the flow from a TEXT description of the week (typed,
/// or dictated via the system keyboard's on-device mic — no app-level speech APIs) → parse
/// (on-device Foundation Models, cloud fallback) → resolve → present the review proposal.
/// Nothing is written here; the review screen commits via saveWeekMeals.
@MainActor
@Observable
final class VoicePlanningCoordinator: Identifiable {
    static let useBallastParse = false

    nonisolated let id = UUID()
    enum Phase: Equatable { case entry, planning, review, error }

    private(set) var phase: Phase = .entry
    private(set) var proposal: [MealUpdateRequest] = []
    private(set) var finalTranscript = ""
    private(set) var errorMessage: String?

    private weak var appState: AppState?
    let weekId: String
    private let weekStart: Date

    init(appState: AppState, weekId: String, weekStart: Date) {
        self.appState = appState
        self.weekId = weekId
        self.weekStart = weekStart
    }

    /// Parse the entered week text → resolve → review.
    func plan(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finalTranscript = trimmed
        errorMessage = nil
        phase = .planning
        guard let appState else { phase = .entry; return }
        do {
            let parsed = try await parse(transcript: trimmed, appState: appState)
            proposal = VoicePlanResolver.resolve(parsed, recipes: appState.recipes, weekStart: weekStart)
            phase = .review
        } catch {
            errorMessage = friendlyError(error)
            phase = .error
        }
    }

    /// Return to the text box (e.g. after an error) to edit + retry.
    func backToEntry() { phase = .entry }

    // The Ballast port remains a separate default-OFF release gate. Its cloud fallback is the
    // shipping CloudParseService, injected at the application boundary.
    private func parse(transcript: String, appState: AppState) async throws -> ParsedWeeklyPlan {
        if Self.useBallastParse {
            let aiSvc = appState.aiService
            let parser = BallastVoicePlanParser(
                fmProvider: GuidedFMParseProvider(),
                isFMAvailable: { OnDeviceParseService.availability() == .available },
                cloudParse: { transcript in
                    guard let aiSvc else { throw VoicePlanningError.noAI }
                    return try await CloudParseService.parse(transcript: transcript, using: aiSvc)
                }
            )
            return try await parser.parse(transcript: transcript)
        }

        // Preserve the shipping default-OFF flow byte-for-byte below this gate.
        if OnDeviceParseService.isEnabled, OnDeviceParseService.availability() == .available {
            do { return try await OnDeviceParseService.parse(transcript: transcript) }
            catch { /* degrade to cloud below */ }
        }
        guard let aiSvc = appState.aiService else { throw VoicePlanningError.noAI }
        return try await CloudParseService.parse(transcript: transcript, using: aiSvc)
    }

    private func friendlyError(_ error: Error) -> String {
        if case VoicePlanningError.noAI = error {
            return "Set up an AI provider in Settings to plan by voice."
        }
        return error.localizedDescription
    }
}

enum VoicePlanningError: Error { case noAI }
