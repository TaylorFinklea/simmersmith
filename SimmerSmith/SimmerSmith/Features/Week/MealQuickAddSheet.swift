import SwiftUI
import SimmerSmithKit

struct MealQuickAddSheet: View {
    let dayName: String
    let mealDate: Date
    let slot: String
    let recipes: [RecipeSummary]
    let onSaveFreeform: (String) async -> Void
    let onSaveRecipe: (RecipeSummary) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mealName = ""
    @State private var isSaving = false
    @State private var showAllRecipes = false
    @State private var recipeSearch = ""

    private var matchingRecipes: [RecipeSummary] {
        let active = recipes.filter { !$0.archived }
        let slotFiltered: [RecipeSummary]
        if showAllRecipes {
            slotFiltered = active
        } else {
            let normalized = slot.lowercased()
            slotFiltered = active.filter {
                let type = $0.mealType.lowercased()
                return type.isEmpty || type == "any" || type == normalized
            }
        }
        let query = recipeSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return slotFiltered }
        return slotFiltered.filter {
            $0.name.lowercased().contains(query) ||
            $0.cuisine.lowercased().contains(query) ||
            $0.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: SMSpacing.lg) {
                        VStack(alignment: .leading, spacing: SMSpacing.xs) {
                            Text("Add \(slot.capitalized)")
                                .font(SMFont.headline)
                                .foregroundStyle(SMColor.textPrimary)

                            Text(dayName)
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                        .padding(.top, SMSpacing.sm)

                        VStack(alignment: .leading, spacing: SMSpacing.sm) {
                            Text("Quick add")
                                .font(SMFont.label)
                                .foregroundStyle(SMColor.textTertiary)

                            TextField("e.g., leftover pizza, grilled chicken...", text: $mealName)
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textPrimary)
                                .padding(SMSpacing.md)
                                .background(SMColor.surfaceCard)
                                .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                                .submitLabel(.done)
                                .onSubmit { saveFreeformIfValid() }
                        }

                        VStack(alignment: .leading, spacing: SMSpacing.sm) {
                            HStack {
                                Text("From recipes")
                                    .font(SMFont.label)
                                    .foregroundStyle(SMColor.textTertiary)

                                Spacer()

                                Button {
                                    showAllRecipes.toggle()
                                } label: {
                                    Text(showAllRecipes ? "Filter by \(slot.capitalized)" : "Show all")
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.primary)
                                }
                                .buttonStyle(.plain)
                            }

                            HStack(spacing: SMSpacing.sm) {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption)
                                    .foregroundStyle(SMColor.textTertiary)

                                TextField("Search recipes...", text: $recipeSearch)
                                    .font(SMFont.body)
                                    .foregroundStyle(SMColor.textPrimary)
                            }
                            .padding(SMSpacing.md)
                            .background(SMColor.surfaceCard)
                            .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))

                            if matchingRecipes.isEmpty {
                                Text(showAllRecipes
                                     ? "No recipes match your search."
                                     : "No \(slot) recipes yet. Tap \"Show all\" or quick add above.")
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textTertiary)
                                    .padding(.vertical, SMSpacing.md)
                            } else {
                                LazyVStack(spacing: SMSpacing.sm) {
                                    ForEach(matchingRecipes) { recipe in
                                        recipeRow(recipe)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, SMSpacing.xl)
                    .padding(.bottom, SMSpacing.xxl)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveFreeformIfValid() }
                        .foregroundStyle(canSaveFreeform ? SMColor.primary : SMColor.textTertiary)
                        .disabled(!canSaveFreeform || isSaving)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func recipeRow(_ recipe: RecipeSummary) -> some View {
        Button {
            guard !isSaving else { return }
            isSaving = true
            Task {
                await onSaveRecipe(recipe)
                dismiss()
            }
        } label: {
            HStack(spacing: SMSpacing.md) {
                VStack(alignment: .leading, spacing: SMSpacing.xs) {
                    Text(recipe.name)
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: SMSpacing.sm) {
                        if !recipe.cuisine.isEmpty {
                            Text(recipe.cuisine)
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.primary)
                        }
                        if !recipe.mealType.isEmpty {
                            Text(recipe.mealType.capitalized)
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(SMColor.primary)
            }
            .padding(SMSpacing.md)
            .background(SMColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private var canSaveFreeform: Bool {
        !mealName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func saveFreeformIfValid() {
        let trimmed = mealName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            await onSaveFreeform(trimmed)
            dismiss()
        }
    }
}
