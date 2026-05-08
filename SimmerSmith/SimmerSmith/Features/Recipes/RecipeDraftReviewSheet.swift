import SwiftUI
import SimmerSmithKit

/// M29 build 53 — the single funnel for every AI-generated recipe
/// draft. Solves the "AI slop" problem by holding the draft in
/// memory until the user explicitly Saves; iterative refinement
/// happens via the AI refine endpoint without ever touching the
/// recipes table.
///
/// Caller flow:
/// 1. Generate a draft via the relevant AI endpoint.
/// 2. Present this sheet with `initialDraft` + a `refineContextHint`
///    that frames the recipe (e.g. "side dish for Lasagna" or
///    "event meal for Easter Brunch").
/// 3. On Save, the sheet calls `onSave(savedSummary)` so the caller
///    can wire the link (event meal, week meal, side, etc.).
/// 4. On Discard, `onDiscard?` fires and nothing persists.
struct RecipeDraftReviewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let initialDraft: RecipeDraft
    let refineContextHint: String
    let onSave: (RecipeSummary) -> Void
    let onDiscard: (() -> Void)?

    @State private var draft: RecipeDraft
    @State private var refinePrompt: String = ""
    @State private var isRefining = false
    @State private var isSaving = false
    @State private var errorMessage: String? = nil
    @State private var refineCount: Int = 0
    @State private var presentingHandEditor: Bool = false

    init(
        initialDraft: RecipeDraft,
        refineContextHint: String = "",
        onSave: @escaping (RecipeSummary) -> Void,
        onDiscard: (() -> Void)? = nil
    ) {
        self.initialDraft = initialDraft
        self.refineContextHint = refineContextHint
        self.onSave = onSave
        self.onDiscard = onDiscard
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection

                Section {
                    TextField(
                        "Tweak it (e.g. less butter, add chives, scale to 2 servings)",
                        text: $refinePrompt,
                        axis: .vertical
                    )
                    .lineLimit(2...4)

                    Button {
                        Task { await refine() }
                    } label: {
                        HStack {
                            if isRefining {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(isRefining ? "Refining…" : "Refine with AI")
                        }
                    }
                    .disabled(
                        isRefining ||
                        refinePrompt.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                } header: {
                    Text("Refine with AI")
                } footer: {
                    if refineCount > 0 {
                        Text("Refined \(refineCount) time\(refineCount == 1 ? "" : "s") · nothing saved yet")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    } else {
                        Text("Iterate as many times as you want — the recipe only gets saved when you tap Save.")
                    }
                }

                Section {
                    Button {
                        presentingHandEditor = true
                    } label: {
                        Label("Edit by hand", systemImage: "pencil")
                    }
                } footer: {
                    Text("Opens the full recipe editor. Saving from there persists the recipe just like Save below.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(SMColor.destructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Review draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) {
                        onDiscard?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .foregroundStyle(SMColor.ember)
                    .disabled(isSaving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .smithToolbar()
            .sheet(isPresented: $presentingHandEditor) {
                RecipeEditorView(
                    title: "Edit before saving",
                    initialDraft: draft
                ) { saved in
                    // Hand-edit Save persists the recipe; bubble that
                    // up to the caller so the link wiring fires.
                    onSave(saved)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text(draft.name)
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)

                HStack(spacing: SMSpacing.md) {
                    if !draft.cuisine.isEmpty {
                        Label(draft.cuisine.capitalized, systemImage: "globe")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    if let servings = draft.servings, servings > 0 {
                        Label("\(Int(servings)) servings", systemImage: "person.2")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    if let prep = draft.prepMinutes, prep > 0 {
                        Label("\(prep)m prep", systemImage: "clock")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }

                if !draft.ingredients.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(draft.ingredients.count) ingredients")
                            .font(SMFont.label)
                            .foregroundStyle(SMColor.textTertiary)
                        ForEach(draft.ingredients.prefix(8)) { ingredient in
                            Text("• \(formatIngredient(ingredient))")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                        if draft.ingredients.count > 8 {
                            Text("…and \(draft.ingredients.count - 8) more")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                }

                if !draft.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(draft.steps.count) steps")
                            .font(SMFont.label)
                            .foregroundStyle(SMColor.textTertiary)
                        ForEach(draft.steps.prefix(3)) { step in
                            Text("\(step.sortOrder + 1). \(step.instruction)")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                        if draft.steps.count > 3 {
                            Text("…and \(draft.steps.count - 3) more")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                }
            }
        } header: {
            Text("Draft")
        }
    }

    private func formatIngredient(_ ingredient: RecipeIngredient) -> String {
        var parts: [String] = []
        if let qty = ingredient.quantity, qty > 0 {
            parts.append(qty.rounded() == qty ? String(Int(qty)) : String(format: "%.2f", qty))
        }
        if !ingredient.unit.isEmpty {
            parts.append(ingredient.unit)
        }
        parts.append(ingredient.ingredientName)
        return parts.joined(separator: " ")
    }

    private func refine() async {
        let prompt = refinePrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        isRefining = true
        defer { isRefining = false }
        errorMessage = nil
        do {
            let refined = try await appState.refineRecipeDraft(
                currentDraft: draft,
                prompt: prompt,
                contextHint: refineContextHint
            )
            draft = refined
            refineCount += 1
            refinePrompt = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        // Build 54: dismiss immediately so the user sees instant
        // progress (the dogfood complaint was "Save took a long
        // time"). The save runs in the background; errors land in
        // `appState.lastErrorMessage` which is surfaced globally so
        // the user is never silently dropped.
        let snapshot = draft
        let onSaveCallback = onSave
        dismiss()
        Task { [weak appState] in
            guard let appState else { return }
            do {
                let saved = try await appState.saveRecipe(snapshot)
                onSaveCallback(saved)
            } catch {
                appState.lastErrorMessage = "Couldn't save recipe: \(error.localizedDescription)"
            }
        }
    }
}
