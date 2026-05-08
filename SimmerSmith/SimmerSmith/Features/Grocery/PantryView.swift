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
///
/// Build 57: a segmented filter routes between regular pantry items,
/// freezer items (frozen_at != nil, sorted oldest-first), and a
/// "Use Soon" cut showing freezer items frozen ≥30 days.
struct PantryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var editorContext: PantryEditorContext? = nil
    @State private var filter: PantryFilter = .all

    private struct PantryEditorContext: Identifiable {
        let id: String
        let item: PantryItem?
        init(_ item: PantryItem? = nil) {
            self.id = item?.pantryItemId ?? "new"
            self.item = item
        }
    }

    enum PantryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case pantry = "Pantry"
        case freezer = "Freezer"
        case useSoon = "Use Soon"

        var id: String { rawValue }
    }

    private var filteredItems: [PantryItem] {
        switch filter {
        case .all:
            return appState.pantryItems
        case .pantry:
            return appState.pantryItems.filter { !$0.isFrozen }
        case .freezer:
            // FIFO — oldest in the freezer surfaces first.
            return appState.pantryItems
                .filter { $0.isFrozen }
                .sorted { ($0.frozenAt ?? .distantFuture) < ($1.frozenAt ?? .distantFuture) }
        case .useSoon:
            return appState.pantryItems
                .filter { $0.isStaleFreezerItem }
                .sorted { ($0.frozenAt ?? .distantFuture) < ($1.frozenAt ?? .distantFuture) }
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            pantryList

            // Build 70 — configurable FAB. Default = ➕ Add pantry item.
            TabPrimaryFAB(page: .pantry, contextHint: "from Pantry", actions: [
                .add: { editorContext = PantryEditorContext() },
                .refresh: { Task { await appState.loadPantryItems() } }
            ])
        }
    }

    @ViewBuilder
    private var pantryList: some View {
        List {
            Section {
                FuHero(
                    eyebrow: pantryHeroEyebrow,
                    title: "the ",
                    emberAccent: "pantry"
                )
                .padding(.horizontal, -SMSpacing.lg)
                .padding(.vertical, SMSpacing.sm)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !appState.pantryItems.isEmpty {
                Section {
                    Picker("Filter", selection: $filter) {
                        ForEach(PantryFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if appState.pantryItems.isEmpty {
                ContentUnavailableView(
                    "Nothing in your pantry yet",
                    systemImage: "shippingbox",
                    description: Text("Add things you always have on hand — eggs, flour, milk. They'll be filtered out of meal-driven grocery lists, and you can opt in to a weekly auto-restock for items you buy on a schedule.")
                )
            } else if filteredItems.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyIcon,
                    description: Text(emptyDescription)
                )
            } else {
                Section {
                    ForEach(filteredItems) { item in
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
                    Text(sectionHeader)
                } footer: {
                    Text(sectionFooter)
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
        .scrollContentBackground(.hidden)
        .paperBackground()
        // Build 70 — top bar holds existing + button + ✨ sparkle.
        // Configurable primary moved to the FAB.
        // Build 71 — hide whichever item is already the FAB.
        .toolbar {
            if pantryPrimary != .add {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorContext = PantryEditorContext()
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(SMColor.ember)
                    }
                    .accessibilityLabel("Add pantry item")
                }
            }
            if pantryPrimary != .sparkle {
                ToolbarItem(placement: .topBarTrailing) {
                    TopBarSparkleButton(contextHint: "from Pantry")
                }
            }
        }
        .smithToolbar()
        .sheet(item: $editorContext) { ctx in
            PantryItemEditorSheet(item: ctx.item)
        }
        .task {
            if appState.pantryItems.isEmpty {
                await appState.loadPantryItems()
            }
        }
    }

    private var pantryPrimary: TopBarPrimaryAction {
        _ = appState.topBarConfigRevision
        return appState.topBarPrimary(for: .pantry)
    }

    private var pantryHeroEyebrow: String {
        let total = appState.pantryItems.count
        if total == 0 { return "what's on hand" }
        let frozen = appState.pantryItems.filter { $0.isFrozen }.count
        let stale = appState.pantryItems.filter { $0.isStaleFreezerItem }.count
        if stale > 0 { return "\(total) items · \(stale) to use soon" }
        if frozen > 0 { return "\(total) items · \(frozen) frozen" }
        return "\(total) items on hand"
    }

    private var sectionHeader: String {
        switch filter {
        case .all: return "Pantry items"
        case .pantry: return "Shelf-stable"
        case .freezer: return "Freezer"
        case .useSoon: return "Use these soon"
        }
    }

    private var sectionFooter: String {
        switch filter {
        case .all:
            return "Items here are always assumed to be in stock — they won't auto-add to your grocery list because of meals. Recurring items will still land each cycle."
        case .pantry:
            return "Regular pantry items (not frozen). Filtered from meal-driven grocery aggregation."
        case .freezer:
            return "Sorted oldest-first. The Use Soon cut highlights anything frozen ≥30 days."
        case .useSoon:
            return "Freezer items that have been sitting for 30+ days. Eat them or toss them — your call."
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .freezer: return "Nothing in the freezer"
        case .useSoon: return "Nothing aging out"
        default: return "No items"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .freezer: return "snowflake"
        case .useSoon: return "checkmark.circle"
        default: return "tray"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .freezer: return "Toggle \"Freezer item\" on a pantry entry to add it here, or save leftovers from a meal."
        case .useSoon: return "Nothing has been in the freezer long enough to surface."
        default: return "Try a different filter."
        }
    }
}

private struct PantryRow: View {
    let item: PantryItem

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                if item.isFrozen {
                    Image(systemName: "snowflake")
                        .font(.caption)
                        .foregroundStyle(SMColor.primary)
                }
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
                if item.isStaleFreezerItem {
                    Text("Use soon")
                        .font(SMFont.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }
            }
            if let frozenLine {
                Text(frozenLine)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
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

    private var frozenLine: String? {
        guard let frozenAt = item.frozenAt, let days = item.daysSinceFrozen else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateText = formatter.string(from: frozenAt)
        if days <= 0 {
            return "Frozen today (\(dateText))"
        }
        return "Frozen \(days)d ago (\(dateText))"
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
