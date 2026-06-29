import Foundation
import Observation
import SimmerSmithKit

/// SP-C voice week-planning — orchestrates the flow: dictate → parse (on-device, else cloud)
/// → resolve → present the review proposal. Owns the DictationService and the phase the UI
/// renders. Nothing is written here; the review screen commits via saveWeekMeals.
@MainActor
@Observable
final class VoicePlanningCoordinator {
    enum Phase: Equatable { case idle, listening, planning, review, error }

    private(set) var phase: Phase = .idle
    private(set) var proposal: [MealUpdateRequest] = []
    private(set) var finalTranscript = ""
    private(set) var errorMessage: String?

    let dictation = DictationService()
    private weak var appState: AppState?
    private(set) var weekId = ""
    private var weekStart = Date()

    init(appState: AppState) { self.appState = appState }

    /// Live transcript for the listening UI.
    var liveTranscript: String { dictation.transcript }

    /// Request permission + start dictation for the given week.
    func begin(weekId: String, weekStart: Date) async {
        self.weekId = weekId
        self.weekStart = weekStart
        errorMessage = nil
        proposal = []
        guard await dictation.requestAuthorization() else {
            errorMessage = "SimmerSmith needs microphone and speech permission to plan by voice. Enable it in Settings."
            phase = .error
            return
        }
        do {
            try dictation.start()
            phase = .listening
        } catch {
            errorMessage = error.localizedDescription
            phase = .error
        }
    }

    /// Stop listening, then parse → resolve → review.
    func finish() async {
        let transcript = dictation.stop()
        finalTranscript = transcript
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .idle
            return
        }
        phase = .planning
        guard let appState else { phase = .idle; return }
        do {
            let parsed = try await parse(transcript: transcript, appState: appState)
            proposal = VoicePlanResolver.resolve(parsed, recipes: appState.recipes, weekStart: weekStart)
            phase = .review
        } catch {
            errorMessage = friendlyError(error)
            phase = .error
        }
    }

    /// Cancel mid-listen — writes nothing.
    func cancel() {
        _ = dictation.stop()
        phase = .idle
    }

    // On-device when eligible, falling back to cloud on ineligibility OR any on-device error.
    private func parse(transcript: String, appState: AppState) async throws -> ParsedWeeklyPlan {
        if OnDeviceParseService.availability() == .available {
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
