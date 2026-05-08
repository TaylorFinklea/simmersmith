import SwiftUI
import SimmerSmithKit

/// Sheet that asks the AI for substitutes for a single recipe ingredient.
/// Picking one rebuilds the recipe draft with that ingredient replaced
/// and persists via the existing saveRecipe upsert flow.
struct SubstitutionSheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let recipe: RecipeSummary
    let ingredient: RecipeIngredient
    /// Fired after `.replace` completes so the parent can refresh in place.
    var onApplied: () -> Void = {}
    /// Fired after `.saveAsVariation` creates a new recipe so the parent
    /// can optionally navigate to it.
    var onVariationCreated: (RecipeSummary) -> Void = { _ in }

    @State private var hint: String = ""
    @State private var isLoading = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var suggestions: [SubstitutionSuggestion] = []
    @State private var hasFetched = false
    // Non-nil while the "replace or save as variation?" dialog is visible.
    // We stash the picked suggestion here so the confirmation handler can
    // route through applySubstitution with the right mode.
    @State private var pendingChoice: SubstitutionSuggestion?

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: SMSpacing.lg) {
                        headerCard

                        hintField

                        if !hasFetched {
                            Button {
                                Task { await fetch() }
                            } label: {
                                HStack(spacing: SMSpacing.sm) {
                                    Image(systemName: "wand.and.stars")
                                    Text("Suggest substitutes")
                                        .font(SMFont.body.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SMSpacing.md)
                                .background(SMColor.primary, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }

                        if isLoading {
                            HStack(spacing: SMSpacing.sm) {
                                ProgressView().controlSize(.small).tint(SMColor.aiPurple)
                                Text("Asking the AI…")
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(SMSpacing.md)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.destructive)
                                .padding(SMSpacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    SMColor.destructive.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous)
                                )
                        }

                        if !suggestions.isEmpty {
                            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                                Text("Suggestions")
                                    .font(SMFont.label)
                                    .foregroundStyle(SMColor.textTertiary)
                                ForEach(suggestions) { suggestion in
                                    suggestionRow(suggestion)
                                }
                            }
                        }

                        if hasFetched && suggestions.isEmpty && !isLoading && errorMessage == nil {
                            Text("No substitutes came back. Try adding a hint above.")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, SMSpacing.lg)
                        }
                    }
                    .padding(SMSpacing.lg)
                }
            }
            .navigationTitle("Substitute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
            .confirmationDialog(
                pendingChoice.map { "Swap with \($0.name)?" } ?? "",
                isPresented: Binding(
                    get: { pendingChoice != nil },
                    set: { if !$0 { pendingChoice = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingChoice
            ) { picked in
                Button("Save as variation") {
                    Task { await apply(picked, mode: .saveAsVariation) }
                }
                Button("Replace this recipe", role: .destructive) {
                    Task { await apply(picked, mode: .replace) }
                }
                Button("Cancel", role: .cancel) {
                    pendingChoice = nil
                }
            } message: { _ in
                Text("Saving as a variation keeps the original recipe next to the swapped version in your library.")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isApplying)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            Text("Replacing")
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)
            Text(ingredient.ingredientName)
                .font(SMFont.body.weight(.semibold))
                .foregroundStyle(SMColor.textPrimary)
            if let quantity = ingredient.quantity, !ingredient.unit.isEmpty {
                Text("\(quantity.formatted()) \(ingredient.unit)")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            } else if let quantity = ingredient.quantity {
                Text(quantity.formatted())
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SMSpacing.md)
        .background(SMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
    }

    private var hintField: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            Text("Why are you swapping? (optional)")
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textSecondary)
            TextField("e.g. \"don't have sour cream\"", text: $hint)
                .font(SMFont.body)
                .foregroundStyle(SMColor.textPrimary)
                .padding(SMSpacing.md)
                .background(
                    SMColor.surfaceCard,
                    in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                )
                .onSubmit { Task { await fetch() } }
        }
    }

    private func suggestionRow(_ suggestion: SubstitutionSuggestion) -> some View {
        Button {
            // Don't mutate the recipe yet — ask whether to overwrite the
            // original or fork a variation first. Tap flows into the
            // confirmationDialog below.
            pendingChoice = suggestion
        } label: {
            HStack(alignment: .top, spacing: SMSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(SMFont.body.weight(.semibold))
                        .foregroundStyle(SMColor.textPrimary)
                    if !suggestion.reason.isEmpty {
                        Text(suggestion.reason)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    if !suggestion.quantity.isEmpty || !suggestion.unit.isEmpty {
                        Text("\(suggestion.quantity) \(suggestion.unit)".trimmingCharacters(in: .whitespaces))
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.primary)
                    }
                }
                Spacer(minLength: SMSpacing.sm)
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(SMColor.primary)
                }
            }
            .padding(SMSpacing.md)
            .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                    .stroke(SMColor.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
    }

    private func fetch() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await appState.apiClient.suggestIngredientSubstitutions(
                recipeID: recipe.recipeId,
                ingredientID: ingredient.id,
                hint: hint.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            suggestions = response.suggestions
            hasFetched = true
        } catch {
            errorMessage = error.localizedDescription
            hasFetched = true
        }
    }

    private func apply(
        _ suggestion: SubstitutionSuggestion,
        mode: AppState.SubstitutionMode
    ) async {
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }
        do {
            let saved = try await appState.applySubstitution(
                recipe: recipe,
                ingredientID: ingredient.id,
                suggestion: suggestion,
                mode: mode
            )
            switch mode {
            case .replace:
                onApplied()
            case .saveAsVariation:
                onVariationCreated(saved)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sheet-routing context so RecipeDetailView can mount the sheet via
/// `.sheet(item:)` with the Identifiable wrapper pattern used elsewhere.
struct SubstitutionSheetContext: Identifiable {
    let id = UUID()
    let recipe: RecipeSummary
    let ingredient: RecipeIngredient
}
