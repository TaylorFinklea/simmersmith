import SwiftUI
import SimmerSmithKit

struct IngredientCatalogList: View {
    let isLoading: Bool
    let ingredients: [BaseIngredient]
    let emptyStateMessage: String

    var body: some View {
        Section {
            if isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading ingredient catalog…")
                        .foregroundStyle(.secondary)
                }
            } else if ingredients.isEmpty {
                ContentUnavailableView(
                    "No Ingredients",
                    systemImage: "shippingbox",
                    description: Text(emptyStateMessage)
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(ingredients) { ingredient in
                    NavigationLink {
                        IngredientDetailView(baseIngredientID: ingredient.baseIngredientId)
                    } label: {
                        IngredientCatalogRow(ingredient: ingredient)
                    }
                }
            }
        } header: {
            Text("Ingredients")
        } footer: {
            if !ingredients.isEmpty {
                Text("\(ingredients.count) ingredient\(ingredients.count == 1 ? "" : "s") loaded")
            }
        }
    }
}

struct IngredientCatalogRow: View {
    let ingredient: BaseIngredient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(ingredient.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if ingredient.provisional {
                    IngredientBadge(title: "Review", tint: .orange)
                } else if ingredient.productLike {
                    IngredientBadge(title: "Product-like", tint: .blue)
                } else if !ingredient.active {
                    IngredientBadge(title: "Archived", tint: .secondary)
                }
            }

            HStack(spacing: 8) {
                if !ingredient.category.isEmpty {
                    Text(ingredient.category)
                }
                if !ingredient.defaultUnit.isEmpty {
                    Text("Unit \(ingredient.defaultUnit)")
                }
                if ingredient.preferenceCount > 0 {
                    Text("Prefs \(ingredient.preferenceCount)")
                }
                if ingredient.variationCount > 0 {
                    Text("Products \(ingredient.variationCount)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let sourceText = ingredientCatalogSourceText(ingredient), !sourceText.isEmpty {
                Text(sourceText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct IngredientBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
