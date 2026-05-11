import SwiftUI
import SimmerSmithKit

/// Build 87 — per-grocery-item store annotation. Tappable chip that
/// shows the current store (or "set store" placeholder when empty),
/// opens a popover listing the household's known store options
/// (Kroger/Aldi/Walmart from profile settings + already-used labels)
/// plus a free-text "Other…" field and a clear option.
///
/// Used by both the regular GroceryView row and the PlanShoppingSheet
/// "Just Added" rows so the user can assign a store the moment they
/// add an item.
struct StoreChip: View {
    @Environment(AppState.self) private var appState

    let item: GroceryItem
    @State private var showingPicker = false
    @State private var customInput = ""

    var body: some View {
        Button {
            customInput = item.storeLabel
            showingPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.storeLabel.isEmpty ? "storefront" : "storefront.fill")
                    .font(.caption2)
                Text(item.storeLabel.isEmpty ? "set store" : item.storeLabel)
                    .font(SMFont.handwritten(13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(item.storeLabel.isEmpty ? SMColor.textTertiary : SMColor.ember)
            .background(
                Capsule()
                    .stroke(item.storeLabel.isEmpty ? SMColor.rule : SMColor.ember.opacity(0.4), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            item.storeLabel.isEmpty
                ? "Set store for \(item.ingredientName)"
                : "Store for \(item.ingredientName): \(item.storeLabel). Tap to change."
        )
        .popover(isPresented: $showingPicker, arrowEdge: .top) {
            picker
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var picker: some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            Text("Store for this item")
                .font(SMFont.subheadline.weight(.semibold))
                .padding(.bottom, 2)

            ForEach(appState.knownStoreOptions, id: \.self) { storeName in
                Button {
                    Task { await appState.setStoreLabel(itemID: item.groceryItemId, storeLabel: storeName) }
                    showingPicker = false
                } label: {
                    HStack {
                        Text(storeName)
                            .foregroundStyle(SMColor.textPrimary)
                        Spacer()
                        if storeName.localizedCaseInsensitiveCompare(item.storeLabel) == .orderedSame {
                            Image(systemName: "checkmark")
                                .foregroundStyle(SMColor.ember)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                TextField("Other store…", text: $customInput)
                    .textFieldStyle(.roundedBorder)
                Button("Set") {
                    Task {
                        await appState.setStoreLabel(
                            itemID: item.groceryItemId,
                            storeLabel: customInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    showingPicker = false
                }
                .buttonStyle(.borderedProminent)
                .tint(SMColor.ember)
                .disabled(customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !item.storeLabel.isEmpty {
                Button(role: .destructive) {
                    Task { await appState.setStoreLabel(itemID: item.groceryItemId, storeLabel: "") }
                    showingPicker = false
                } label: {
                    Label("Clear store", systemImage: "xmark.circle")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SMColor.destructive)
            }
        }
        .padding(SMSpacing.md)
        .frame(minWidth: 260)
    }
}
