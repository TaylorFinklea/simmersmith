import SwiftUI
import SimmerSmithKit

/// Lists grocery items that the server has marked as
/// `is_user_removed=true` (tombstones). Smart-merge regen keeps these
/// rows so a removed-then-still-in-meals item stays removed; this
/// sheet lets the user reverse that decision when an item disappeared
/// unexpectedly (e.g., from a stale Reminders fetch in build 35/36).
///
/// Calls the existing M22 delta endpoint without a `since` cursor so
/// we get the full set including tombstones, then filters to the
/// removed ones for display.
struct GroceryArchiveSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [GroceryItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var restoringIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No removed items.")
                            .font(.headline)
                        Text("Items you swipe-remove from the Grocery tab show up here so you can put them back.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            Button {
                                Task { await restoreAll() }
                            } label: {
                                Label("Restore all (\(items.count))", systemImage: "arrow.uturn.backward.circle")
                            }
                            .disabled(!restoringIDs.isEmpty)
                        }
                        Section("Removed") {
                            ForEach(items) { item in
                                row(for: item)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Removed Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
            .task { await load() }
        }
    }

    @ViewBuilder
    private func row(for item: GroceryItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.ingredientName)
                    .font(.body)
                if let qty = item.totalQuantity ?? item.quantityOverride {
                    Text(qtyLabel(qty: qty, unit: item.effectiveUnit, qText: item.quantityText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !item.quantityText.isEmpty {
                    Text(item.quantityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if restoringIDs.contains(item.groceryItemId) {
                ProgressView()
            } else {
                Button("Restore") {
                    Task { await restore(id: item.groceryItemId) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func qtyLabel(qty: Double, unit: String, qText: String) -> String {
        let qtyString = qty.rounded() == qty ? String(Int(qty)) : String(format: "%g", qty)
        if !unit.isEmpty { return "\(qtyString) \(unit)" }
        if !qText.isEmpty { return qText }
        return qtyString
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let weekID = appState.currentWeek?.weekId else {
            errorMessage = "No week loaded yet. Pull to refresh on the Week tab and try again."
            return
        }
        do {
            let delta = try await appState.apiClient.fetchGroceryDelta(weekID: weekID, since: nil)
            items = delta.items.filter(\.isUserRemoved)
                .sorted { $0.ingredientName.localizedCaseInsensitiveCompare($1.ingredientName) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(id: String) async {
        guard let weekID = appState.currentWeek?.weekId else { return }
        restoringIDs.insert(id)
        defer { restoringIDs.remove(id) }
        do {
            var body = SimmerSmithAPIClient.GroceryItemPatchBody()
            body.removed = false
            let restored = try await appState.apiClient.patchGroceryItem(
                weekID: weekID, itemID: id, body: body
            )
            items.removeAll { $0.groceryItemId == id }
            appState.insertGroceryItemInCurrentWeek(restored)
            await appState.syncGroceryToReminders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreAll() async {
        guard let weekID = appState.currentWeek?.weekId else { return }
        let toRestore = items
        for item in toRestore {
            restoringIDs.insert(item.groceryItemId)
        }
        defer { restoringIDs.removeAll() }
        for item in toRestore {
            do {
                var body = SimmerSmithAPIClient.GroceryItemPatchBody()
                body.removed = false
                let restored = try await appState.apiClient.patchGroceryItem(
                    weekID: weekID, itemID: item.groceryItemId, body: body
                )
                appState.insertGroceryItemInCurrentWeek(restored)
            } catch {
                print("[GroceryArchiveSheet] restore \(item.groceryItemId) failed: \(error)")
            }
        }
        items = []
        await appState.syncGroceryToReminders()
    }
}
