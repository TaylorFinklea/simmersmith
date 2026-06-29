import SwiftUI

/// SP-C voice week-planning — the assistant-composer entry point: a mic that dictates speech
/// into the bound text field (pure dictation; the dedicated Week button owns the full review
/// flow). Self-contained so the composer edit is a single insertion.
struct ComposerMicButton: View {
    @Binding var text: String
    /// Drives the composer to disable its TextField while dictating, so edits can't race the
    /// live transcript merge (and get discarded on the next onChange).
    @Binding var isDictating: Bool
    @State private var dictation = DictationService()
    @State private var baseText = ""

    var body: some View {
        Button {
            Task {
                if dictation.isListening {
                    _ = dictation.stop()
                    isDictating = false
                } else {
                    baseText = text
                    guard await dictation.requestAuthorization() else { return }
                    try? dictation.start()
                    isDictating = dictation.isListening
                }
            }
        } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                .font(.system(size: 22))
                .foregroundStyle(dictation.isListening ? SMColor.accent : SMColor.textSecondary)
        }
        .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate")
        .onChange(of: dictation.transcript) { _, spoken in
            // Live: append the dictation to whatever was in the field when we started.
            if baseText.isEmpty { text = spoken }
            else if spoken.isEmpty { text = baseText }
            else { text = baseText + " " + spoken }
        }
    }
}

/// SP-C voice week-planning — the Week-tab entry point. Tapping launches the listening sheet,
/// which walks listen → plan → review in one place (content switches by coordinator phase).
struct VoicePlanningButton: View {
    let weekId: String
    let weekStart: Date

    @Environment(AppState.self) private var appState
    @State private var coordinator: VoicePlanningCoordinator?
    @State private var showing = false

    var body: some View {
        Button {
            coordinator = VoicePlanningCoordinator(appState: appState)
            showing = true
        } label: {
            Label("Plan by voice", systemImage: "mic.fill")
        }
        .sheet(isPresented: $showing, onDismiss: { coordinator = nil }) {
            if let coordinator {
                VoicePlanningListeningSheet(coordinator: coordinator, weekId: weekId, weekStart: weekStart)
            }
        }
    }
}

/// The single sheet that drives the whole voice flow; its body switches on the coordinator's
/// phase so the listen → plan → review hand-offs need no nested sheets.
struct VoicePlanningListeningSheet: View {
    let coordinator: VoicePlanningCoordinator
    let weekId: String
    let weekStart: Date

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch coordinator.phase {
            case .idle, .listening:
                listening
            case .planning:
                planning
            case .review:
                VoicePlanReviewView(
                    weekId: coordinator.weekId,
                    transcript: coordinator.finalTranscript,
                    proposal: coordinator.proposal
                )
            case .error:
                errorView
            }
        }
        .task { await coordinator.begin(weekId: weekId, weekStart: weekStart) }
    }

    private var listening: some View {
        VStack(spacing: SMSpacing.lg) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(SMColor.accent)
                .symbolEffect(.pulse)
            Text("Talk out your week")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
            Text("e.g. \"Monday taco night, Tuesday leftovers, order pizza Friday.\"")
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SMSpacing.lg)

            ScrollView {
                Text(coordinator.liveTranscript.isEmpty ? "Listening…" : coordinator.liveTranscript)
                    .font(SMFont.subheadline)
                    .foregroundStyle(coordinator.liveTranscript.isEmpty ? SMColor.textTertiary : SMColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 180)

            Spacer()
            Button {
                Task { await coordinator.finish() }
            } label: {
                Label("Stop & review", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, SMSpacing.lg)

            Button("Cancel") {
                coordinator.cancel()
                dismiss()
            }
            .padding(.bottom, SMSpacing.md)
        }
    }

    private var planning: some View {
        VStack(spacing: SMSpacing.md) {
            ProgressView()
            Text("Planning your week…")
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: SMSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(SMColor.accent)
            Text(coordinator.errorMessage ?? "Something went wrong.")
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SMSpacing.lg)
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
