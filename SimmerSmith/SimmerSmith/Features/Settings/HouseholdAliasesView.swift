import SwiftUI
import SimmerSmithKit

/// M26 Phase 3 — manage the per-household shorthand dictionary.
///
/// Each row is `term → expansion` (e.g. `chx → chicken`). Both the
/// week planner and the assistant inject this map into their system
/// prompt as a "treat term as expansion" preamble, so the user can
/// type `give me a chx recipe` and the AI handles it correctly.
struct HouseholdAliasesView: View {
    @Environment(AppState.self) private var appState

    @State private var newTerm: String = ""
    @State private var newExpansion: String = ""
    @State private var newNotes: String = ""
    @State private var isWorking = false
    @State private var errorMessage: String? = nil

    var body: some View {
        Form {
            Section {
                if appState.householdAliases.isEmpty {
                    Text("No custom terms yet — add one below.")
                        .foregroundStyle(SMColor.textTertiary)
                } else {
                    ForEach(appState.householdAliases) { alias in
                        VStack(alignment: .leading, spacing: SMSpacing.xs) {
                            HStack {
                                Text(alias.term)
                                    .font(SMFont.subheadline.monospaced())
                                    .foregroundStyle(SMColor.textPrimary)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(SMColor.textTertiary)
                                Text(alias.expansion)
                                    .font(SMFont.subheadline)
                                    .foregroundStyle(SMColor.textPrimary)
                            }
                            if !alias.notes.isEmpty {
                                Text(alias.notes)
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textSecondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await appState.deleteHouseholdAlias(term: alias.term) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Custom terms")
            } footer: {
                Text("The AI treats each term as if you typed the expansion. Useful for shorthand like \"chx → chicken\" or brand abbreviations.")
            }

            Section {
                TextField("Term (e.g. chx)", text: $newTerm)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Expansion (e.g. chicken)", text: $newExpansion)
                TextField("Notes (optional)", text: $newNotes, axis: .vertical)
                    .lineLimit(1...3)
                Button {
                    Task { await add() }
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Label("Add term", systemImage: "plus.circle.fill")
                    }
                }
                .disabled(
                    isWorking ||
                    newTerm.trimmingCharacters(in: .whitespaces).isEmpty ||
                    newExpansion.trimmingCharacters(in: .whitespaces).isEmpty
                )
            } header: {
                Text("Add a term")
            } footer: {
                Text("Terms are case-insensitive — \"CHX\", \"Chx\", and \"chx\" share one slot.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(SMColor.destructive)
                }
            }
        }
        .navigationTitle("Custom terms")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await appState.loadHouseholdAliases()
        }
    }

    private func add() async {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        let expansion = newExpansion.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !expansion.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        await appState.upsertHouseholdAlias(term: term, expansion: expansion, notes: newNotes)
        newTerm = ""
        newExpansion = ""
        newNotes = ""
        errorMessage = nil
    }
}
