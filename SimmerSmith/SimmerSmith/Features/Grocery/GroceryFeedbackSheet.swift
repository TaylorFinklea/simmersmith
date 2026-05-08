import SwiftUI
import SimmerSmithKit

/// Replaces the generic FeedbackComposer for grocery rows. Combines
/// the existing sentiment + notes capture (feeds the planner's
/// preference signals) with a one-tap brand preference setter so the
/// user can mark "this brand is my primary" or "this is my secondary
/// fallback" directly from the shopping context — same workflow they
/// already use to give the planner thumbs-up/down feedback.
struct GroceryFeedbackSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: GroceryItem

    @State private var sentiment = 0
    @State private var notes: String = ""
    @State private var pinAction: PinAction = .none
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingLinker = false

    enum PinAction: Hashable {
        case none
        case primary
        case secondary
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "cart")
                            .foregroundStyle(SMColor.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.ingredientName)
                                .font(.body.weight(.semibold))
                            if let variation = item.ingredientVariationName, !variation.isEmpty {
                                Text(variation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if !item.preferredBrandHint.isEmpty {
                                Text(item.preferredBrandHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingLinker = true
                    } label: {
                        HStack {
                            Label(canSetPreference ? "Re-link to Ingredient" : "Link to Ingredient",
                                  systemImage: "link")
                            Spacer()
                            if let base = item.baseIngredientName, !base.isEmpty {
                                Text(base)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Catalog ingredient")
                } footer: {
                    if canSetPreference {
                        Text("Linked to a canonical entry — smart-merge regen and brand preferences both apply.")
                    } else {
                        Text("This item isn't linked yet. Pick a canonical entry so smart-merge stays consistent and brand preferences become available.")
                    }
                }

                if canSetPreference {
                    Section {
                        Picker("Brand preference", selection: $pinAction) {
                            Text("No change").tag(PinAction.none)
                            Text("Pin as Primary").tag(PinAction.primary)
                            Text("Pin as Secondary").tag(PinAction.secondary)
                        }
                        .pickerStyle(.segmented)

                        currentPreferenceSummary
                    } header: {
                        Text("Brand preference")
                    } footer: {
                        Text("Pinning saves \(pinSubject) as the default for \(item.baseIngredientName ?? item.ingredientName). Primary is the first pick; Secondary is the fallback when the primary is out.")
                    }
                }

                Section("Sentiment") {
                    Picker("Sentiment", selection: $sentiment) {
                        Text("Avoid").tag(-2)
                        Text("Bad").tag(-1)
                        Text("Neutral").tag(0)
                        Text("Good").tag(1)
                        Text("Great").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .foregroundStyle(SMColor.ember)
                    .disabled(isSaving)
                }
            }
            .smithToolbar()
            .sheet(isPresented: $showingLinker) {
                IngredientLinkPickerSheet(item: item) { _ in
                    // Linker fires onLinked + dismisses itself. Bounce
                    // the feedback sheet too — the user reopens it
                    // fresh on the now-resolved row to set the
                    // preference. Keeps the state model simple.
                    dismiss()
                }
                .environment(appState)
            }
        }
    }

    private var canSetPreference: Bool {
        // Need a base ingredient so the preference resolves to a
        // catalog row. Without a base we'd be saving an orphan
        // preferred_brand which the planner can't apply.
        item.baseIngredientId != nil && !(item.baseIngredientId?.isEmpty ?? true)
    }

    private var pinSubject: String {
        if let variation = item.ingredientVariationName, !variation.isEmpty {
            return "\"\(variation)\""
        }
        return "\"\(item.ingredientName)\""
    }

    @ViewBuilder
    private var currentPreferenceSummary: some View {
        let existing = appState.ingredientPreferences
            .filter { $0.baseIngredientId == item.baseIngredientId }
            .sorted { $0.rank < $1.rank }
        if existing.isEmpty {
            Text("No preferences set yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(existing) { preference in
                HStack {
                    Text(rankLabelText(preference.rank))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SMColor.aiPurple.opacity(0.15), in: Capsule())
                        .foregroundStyle(SMColor.aiPurple)
                    Text(preference.preferredVariationName?.isEmpty == false
                         ? preference.preferredVariationName!
                         : (preference.preferredBrand.isEmpty ? "Generic" : preference.preferredBrand))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func rankLabelText(_ rank: Int) -> String {
        switch rank {
        case 1: return "Primary"
        case 2: return "Secondary"
        case 3: return "Tertiary"
        default: return "#\(rank)"
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        // Sentiment + notes — existing feedback signal pipeline.
        do {
            try await appState.submitGroceryFeedback(
                for: item,
                sentiment: sentiment,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // Brand preference, if the user pinned one.
        if pinAction != .none, let baseID = item.baseIngredientId {
            let rank = pinAction == .primary ? 1 : 2
            // If there's already a preference at this rank, update it
            // (upsert keys on (user, base, rank)). Otherwise create new.
            let existing = appState.ingredientPreferences
                .first { $0.baseIngredientId == baseID && $0.rank == rank }
            do {
                _ = try await appState.upsertIngredientPreference(
                    preferenceID: existing?.preferenceId,
                    baseIngredientID: baseID,
                    preferredVariationID: item.ingredientVariationId,
                    preferredBrand: item.preferredBrandHint,
                    choiceMode: "preferred",
                    active: true,
                    notes: existing?.notes ?? "",
                    rank: rank
                )
            } catch {
                errorMessage = "Saved feedback, but pinning brand failed: \(error.localizedDescription)"
                return
            }
        }

        dismiss()
    }
}


private extension GroceryItem {
    /// Best-effort brand name string for the preference free-text
    /// field — the variation name when present, falling back to the
    /// ingredient name so a catalog-resolved item without a specific
    /// variation still records something meaningful.
    var preferredBrandHint: String {
        if let variation = ingredientVariationName, !variation.isEmpty { return variation }
        return ingredientName
    }
}
