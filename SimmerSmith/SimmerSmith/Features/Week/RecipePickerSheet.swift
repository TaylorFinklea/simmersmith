import SwiftUI
import SimmerSmithKit

struct RecipePickerSheet: View {
    let meal: WeekMeal
    let recipes: [RecipeSummary]
    let onSelect: (RecipeSummary) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isLinking = false
    /// Build 57 — Quick filter chip mirrors the Recipes tab predicate
    /// so a user picking dinner at 6pm can narrow to ≤30-min options.
    @State private var quickOnly = false

    private var filteredRecipes: [RecipeSummary] {
        var active = recipes.filter { !$0.archived }
        if quickOnly {
            active = active.filter { recipe in
                if recipe.tags.contains("quick") { return true }
                let total = (recipe.prepMinutes ?? 0) + (recipe.cookMinutes ?? 0)
                return total > 0 && total <= 30
            }
        }
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return active
        }
        let query = searchText.lowercased()
        return active.filter {
            $0.name.lowercased().contains(query) ||
            $0.cuisine.lowercased().contains(query) ||
            $0.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(spacing: SMSpacing.sm) {
                        Text("Link to Recipe")
                            .font(SMFont.headline)
                            .foregroundStyle(SMColor.textPrimary)

                        Text(meal.recipeName)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    }
                    .padding(.top, SMSpacing.lg)
                    .padding(.bottom, SMSpacing.md)

                    HStack(spacing: SMSpacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(SMColor.textTertiary)

                        TextField("Search recipes...", text: $searchText)
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textPrimary)
                    }
                    .padding(SMSpacing.md)
                    .background(SMColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                    .padding(.horizontal, SMSpacing.lg)
                    .padding(.bottom, SMSpacing.sm)

                    HStack(spacing: SMSpacing.sm) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                quickOnly.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.caption2)
                                Text("Quick (≤30 min)")
                                    .font(SMFont.caption)
                            }
                            .foregroundStyle(quickOnly ? SMColor.primary : SMColor.textSecondary)
                            .padding(.horizontal, SMSpacing.md)
                            .padding(.vertical, 6)
                            .background(SMColor.surfaceCard)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(quickOnly ? SMColor.primary : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, SMSpacing.lg)
                    .padding(.bottom, SMSpacing.md)

                    if filteredRecipes.isEmpty {
                        VStack(spacing: SMSpacing.sm) {
                            Spacer()
                            Image(systemName: "book.closed")
                                .font(.system(size: 32))
                                .foregroundStyle(SMColor.textTertiary)
                            Text("No recipes found")
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)
                            if !searchText.isEmpty {
                                Text("Try a different search term")
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textTertiary)
                            }
                            Spacer()
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: SMSpacing.sm) {
                                ForEach(filteredRecipes) { recipe in
                                    Button {
                                        guard !isLinking else { return }
                                        isLinking = true
                                        Task {
                                            await onSelect(recipe)
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
                                                        Text(recipe.mealType)
                                                            .font(SMFont.caption)
                                                            .foregroundStyle(SMColor.textTertiary)
                                                    }
                                                }
                                            }

                                            Spacer()

                                            Image(systemName: "link")
                                                .font(.caption)
                                                .foregroundStyle(SMColor.textTertiary)
                                        }
                                        .padding(SMSpacing.md)
                                        .background(SMColor.surfaceCard)
                                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isLinking)
                                }
                            }
                            .padding(.horizontal, SMSpacing.lg)
                            .padding(.bottom, SMSpacing.xxl)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            searchText = meal.recipeName
        }
    }
}
