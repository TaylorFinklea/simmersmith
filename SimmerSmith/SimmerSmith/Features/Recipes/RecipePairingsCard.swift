import SimmerSmithKit
import SwiftUI

/// Collapsed-by-default suggestions card. The user has to tap "Suggest
/// pairings" to spend the AI call — this avoids burning a request on
/// every recipe-detail open.
struct RecipePairingsCard: View {
    @Environment(AppState.self) private var appState

    let recipeID: String

    @State private var pairings: [PairingOption] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.md) {
            Text("Pair with")
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)
                .padding(.leading, SMSpacing.xs)

            if hasLoaded {
                if pairings.isEmpty {
                    SMCard {
                        Text("No pairings came back this time. Try again?")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                } else {
                    ForEach(pairings) { pairing in
                        SMCard {
                            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                                HStack {
                                    Text(pairing.name)
                                        .font(SMFont.headline)
                                        .foregroundStyle(SMColor.textPrimary)
                                    Spacer()
                                    roleChip(pairing.role)
                                }
                                if !pairing.reason.isEmpty {
                                    Text(pairing.reason)
                                        .font(SMFont.body)
                                        .foregroundStyle(SMColor.textSecondary)
                                }
                            }
                        }
                    }
                }

                Button {
                    Task { await load(force: true) }
                } label: {
                    Label("Suggest different pairings", systemImage: "arrow.clockwise")
                        .font(SMFont.body)
                }
                .disabled(isLoading)
            } else {
                SMCard {
                    Button {
                        Task { await load(force: false) }
                    } label: {
                        HStack(spacing: SMSpacing.sm) {
                            Image(systemName: "fork.knife")
                                .foregroundStyle(SMColor.primary)
                            Text(isLoading ? "Asking AI…" : "Suggest pairings")
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textPrimary)
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(SMColor.textTertiary)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(SMFont.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func roleChip(_ role: String) -> some View {
        Text(role.capitalized)
            .font(.caption.weight(.medium))
            .foregroundStyle(SMColor.primary)
            .padding(.horizontal, SMSpacing.sm)
            .padding(.vertical, 4)
            .background(SMColor.primary.opacity(0.12))
            .clipShape(Capsule())
    }

    private func load(force: Bool) async {
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let suggestions = try await appState.suggestRecipePairings(recipeID: recipeID)
            self.pairings = suggestions
            self.hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
