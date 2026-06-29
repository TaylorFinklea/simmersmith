import SwiftUI

/// SP-C voice week-planning — the Week-tab entry point. Opens a text box where the user dictates
/// with the system keyboard's on-device mic OR just types, then parses → review → apply. No
/// app-level audio/speech APIs (that surface caused an AVAudioEngine queue crash and is deferred
/// to iOS 27 third-party dictation). The sheet body switches on the coordinator phase.
struct VoicePlanningButton: View {
    let weekId: String
    let weekStart: Date

    @Environment(AppState.self) private var appState
    @State private var coordinator: VoicePlanningCoordinator?
    @State private var showing = false

    var body: some View {
        Button {
            coordinator = VoicePlanningCoordinator(appState: appState, weekId: weekId, weekStart: weekStart)
            showing = true
        } label: {
            Label("Plan by voice", systemImage: "mic.fill")
        }
        .sheet(isPresented: $showing, onDismiss: { coordinator = nil }) {
            if let coordinator {
                VoicePlanSheet(coordinator: coordinator)
            }
        }
    }
}

struct VoicePlanSheet: View {
    let coordinator: VoicePlanningCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        switch coordinator.phase {
        case .entry:
            entry
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

    private var entry: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Tap the mic on your keyboard to dictate, or just type. Give the day and meal for each one.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
                    .padding(.horizontal, SMSpacing.lg)
                    .padding(.top, SMSpacing.sm)

                TextEditor(text: $text)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(SMSpacing.sm)
                    .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("e.g. Monday taco night, Tuesday leftovers, that salmon recipe Wednesday, order pizza Friday, skip breakfast Thursday")
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textTertiary)
                                .padding(SMSpacing.md)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, SMSpacing.lg)
                    .padding(.bottom, SMSpacing.lg)
            }
            .navigationTitle("Plan your week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { Task { await coordinator.plan(text: text) } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { editorFocused = true }
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
            HStack(spacing: SMSpacing.md) {
                Button("Edit") { coordinator.backToEntry() }
                    .buttonStyle(.bordered)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
