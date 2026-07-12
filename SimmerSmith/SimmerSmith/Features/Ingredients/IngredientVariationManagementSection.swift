import SwiftUI
import SimmerSmithKit

struct IngredientVariationManagementSection: View {
    let variations: [IngredientVariation]
    let canManage: Bool
    let onCreateVariation: () -> Void
    let onEditVariation: (IngredientVariation) -> Void
    let onArchiveVariation: (IngredientVariation) -> Void

    var body: some View {
        Section("Products") {
            if variations.isEmpty {
                Text("No product variations yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(variations) { variation in
                    IngredientVariationRow(
                        variation: variation,
                        canManage: canManage,
                        onEdit: { onEditVariation(variation) },
                        onArchive: { onArchiveVariation(variation) }
                    )
                }
            }

            if canManage {
                Button(action: onCreateVariation) {
                    Label("Add Product Variation", systemImage: "plus.circle")
                }
            }
        }
    }
}

private struct IngredientVariationRow: View {
    let variation: IngredientVariation
    let canManage: Bool
    let onEdit: () -> Void
    let onArchive: () -> Void

    var body: some View {
        if canManage {
            Button(action: onEdit) {
                rowContent
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Edit", action: onEdit)
                Button("Archive", role: .destructive, action: onArchive)
            }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(variation.brand.isEmpty ? variation.name : "\(variation.brand) • \(variation.name)")
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                if let amount = variation.packageSizeAmount, !variation.packageSizeUnit.isEmpty {
                    Text("\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(variation.packageSizeUnit)")
                }
                if let count = variation.countPerPackage {
                    Text("\(count.formatted(.number.precision(.fractionLength(0...2)))) per pack")
                }
                if !variation.upc.isEmpty {
                    Text("UPC \(variation.upc)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}
