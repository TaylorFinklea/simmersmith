import Foundation
import Observation
import SimmerSmithKit

/// SP-C voice week-planning — orchestrates the flow from a TEXT description of the week (typed,
/// or dictated via the system keyboard's on-device mic — no app-level speech APIs) → parse
/// (on-device Foundation Models, cloud fallback) → resolve → present the review proposal.
/// Nothing is written here; the review screen commits via saveWeekMeals.
@MainActor
@Observable
final class VoicePlanningCoordinator {
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

    // On-device parsing is feature-flagged OFF for now (OnDeviceParseService.isEnabled): voice
    // parsing uses the configured cloud model from Settings. When the flag is on, prefer
    // on-device on eligible hardware and fall back to cloud on ineligibility OR any error.
    private func parse(transcript: String, appState: AppState) async throws -> ParsedWeeklyPlan {
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
