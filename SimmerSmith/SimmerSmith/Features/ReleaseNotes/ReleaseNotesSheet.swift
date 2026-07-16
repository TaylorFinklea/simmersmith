import SwiftUI

/// The What's New sheet.
///
/// Renders whatever notes it is handed and nothing more — it does not decide
/// what should be shown (that's `ReleaseNotesGate`) and it does not record that
/// it was shown (that's the presenter's `onDismiss`). So the same view serves
/// both the once-per-update sheet at launch and the full history in Settings.
struct ReleaseNotesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: ReleaseNotesPresentation

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.paper.ignoresSafeArea()
                PaperGrain().ignoresSafeArea()

                ScrollView {
                    VStack(spacing: SMSpacing.xl) {
                        FuMark(size: 48, color: SMColor.ink, ember: SMColor.ember)
                            .padding(.top, SMSpacing.sm)

                        ReleaseNotesEntries(notes: presentation.notes)

                        if !presentation.previousNotes.isEmpty {
                            NavigationLink {
                                PreviousReleasesView(
                                    notes: presentation.previousNotes,
                                    close: { dismiss() }
                                )
                            } label: {
                                HStack(spacing: SMSpacing.sm) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .accessibilityHidden(true)
                                    Text("Previous Releases")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .accessibilityHidden(true)
                                }
                                .font(SMFont.label)
                                .foregroundStyle(SMColor.ember)
                                .padding(.horizontal, SMSpacing.lg)
                                .padding(.vertical, SMSpacing.md)
                                .background(
                                    SMColor.paperAlt,
                                    in: RoundedRectangle(
                                        cornerRadius: SMRadius.md,
                                        style: .continuous
                                    )
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: SMRadius.md,
                                        style: .continuous
                                    )
                                    .stroke(SMColor.ember.opacity(0.35), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows earlier release notes")
                        }

                        Button {
                            dismiss()
                        } label: {
                            FuEmberCTA(label: "Got it")
                        }
                        .buttonStyle(.plain)
                        .padding(.top, SMSpacing.sm)
                    }
                    .padding(.horizontal, SMSpacing.xl)
                    .padding(.vertical, SMSpacing.xl)
                }
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
        }
        .presentationDetents([.large])
    }
}

private struct PreviousReleasesView: View {
    let notes: [ReleaseNote]
    let close: () -> Void

    var body: some View {
        ZStack {
            SMColor.paper.ignoresSafeArea()
            PaperGrain().ignoresSafeArea()

            ScrollView {
                ReleaseNotesEntries(notes: notes)
                    .padding(.horizontal, SMSpacing.xl)
                    .padding(.vertical, SMSpacing.xl)
            }
        }
        .navigationTitle("Previous Releases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close", action: close)
                    .foregroundStyle(SMColor.ember)
            }
        }
        .smithToolbar()
    }
}

private struct ReleaseNotesEntries: View {
    let notes: [ReleaseNote]

    var body: some View {
        VStack(spacing: SMSpacing.xl) {
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 {
                    DashedRule()
                        .padding(.vertical, SMSpacing.xs)
                }
                release(note)
            }
        }
    }

    private func release(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.lg) {
            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                Text(note.headline)
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                FuEyebrow(text: note.date, ember: true)

                // Small and quiet — but present, because "which build are you
                // on?" is the first question any bug report needs answered.
                Text("Version \(note.version) (\(note.build))")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            group("New", systemImage: "sparkles", items: note.new)
            group("Improved", systemImage: "hammer", items: note.improved)
            group("Fixed", systemImage: "wrench.and.screwdriver", items: note.fixed)
        }
    }

    @ViewBuilder
    private func group(_ title: String, systemImage: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                HStack(spacing: SMSpacing.xs) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(SMColor.ember)
                    FuEyebrow(text: title, ember: true)
                }

                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: SMSpacing.sm) {
                        Text("—")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.ember.opacity(0.65))
                        Text(item)
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
