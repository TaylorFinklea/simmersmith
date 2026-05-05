import SwiftUI
import SimmerSmithKit

/// M28 — pantry list. Reachable from the Grocery tab.
///
/// Pantry items are filtered out of meal-driven grocery aggregation
/// (the existing `staples` filter), AND can carry an optional
/// recurring auto-add (e.g. "5 dozen eggs each week"). Recurrings
/// land as user-added grocery rows via
/// `apply_pantry_recurrings` — wired to the regen path AND a
/// manual "Apply to current week" button below.
struct PantryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var editorContext: PantryEditorContext? = nil

    private struct PantryEditorContext: Identifiable {
        let id: String
        let item: PantryItem?
        init(_ item: PantryItem? = nil) {
            self.id = item?.pantryItemId ?? "new"
            self.item = item
        }
    }

    var body: some View {
        List {
            if appState.pantryItems.isEmpty {
                ContentUnavailableView(
                    "Nothing in your pantry yet",
                    systemImage: "shippingbox",
                    description: Text("Add things you always have on hand — eggs, flour, milk. They'll be filtered out of meal-driven grocery lists, and you can opt in to a weekly auto-restock for items you buy on a schedule.")
                )
            } else {
                Section {
                    ForEach(appState.pantryItems) { item in
                        Button {
                            editorContext = PantryEditorContext(item)
                        } label: {
                            PantryRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await appState.deletePantryItem(itemID: item.pantryItemId) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Pantry items")
                } footer: {
                    Text("Items here are always assumed to be in stock — they won't auto-add to your grocery list because of meals. Recurring items will still land each cycle.")
                }
            }

            if !appState.pantryItems.isEmpty, appState.currentWeek != nil {
                Section {
                    Button {
                        Task { await appState.applyPantryToCurrentWeek() }
                    } label: {
                        Label("Apply recurrings to this week", systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text("Force a re-fold for the current week — useful right after editing a recurring quantity.")
                }
            }
        }
        .navigationTitle("Pantry")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorContext = PantryEditorContext()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editorContext) { ctx in
            PantryItemEditorSheet(item: ctx.item)
        }
        .task {
            if appState.pantryItems.isEmpty {
                await appState.loadPantryItems()
            }
        }
    }
}

private struct PantryRow: View {
    let item: PantryItem

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.stapleName)
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textPrimary)
                Spacer()
                if !item.isActive {
                    Text("Paused")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
                if item.hasRecurring {
                    Label(cadenceLabel, systemImage: "arrow.triangle.2.circlepath")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.primary)
                }
            }
            if let typical = quantityLine(qty: item.typicalQuantity, unit: item.typicalUnit, prefix: "Typical buy:") {
                Text(typical)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            }
            if let recurring = quantityLine(qty: item.recurringQuantity, unit: item.recurringUnit, prefix: "Restock:") {
                Text(recurring)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            }
            if !item.notes.isEmpty {
                Text(item.notes)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var cadenceLabel: String {
        switch item.recurringCadence {
        case "weekly": return "Weekly"
        case "biweekly": return "Biweekly"
        case "monthly": return "Monthly"
        default: return ""
        }
    }

    private func quantityLine(qty: Double?, unit: String, prefix: String) -> String? {
        guard let qty, qty > 0 else { return nil }
        let qtyText: String
        if qty.rounded() == qty {
            qtyText = String(Int(qty))
        } else {
            qtyText = String(format: "%.1f", qty).trimmingCharacters(in: CharacterSet(charactersIn: "0").union(CharacterSet(charactersIn: ".")))
        }
        let unitText = unit.isEmpty ? "" : " \(unit)"
        return "\(prefix) \(qtyText)\(unitText)"
    }
}
