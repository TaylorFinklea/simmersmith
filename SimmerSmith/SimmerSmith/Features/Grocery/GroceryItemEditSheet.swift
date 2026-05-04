import SwiftUI
import SimmerSmithKit

/// Sheet for editing a grocery item's quantity, unit, and notes. For
/// auto-aggregated items, edits write to the `*Override` fields so
/// smart-merge regeneration preserves them. For user-added items,
/// edits update the row directly. A "Reset to auto" button clears the
/// overrides on auto-aggregated rows; not shown for user-added items.
struct GroceryItemEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: GroceryItem

    @State private var quantityText: String
    @State private var unit: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var showingLinker = false

    init(item: GroceryItem) {
        self.item = item
        let qty = item.effectiveQuantity
        _quantityText = State(initialValue: qty.map { $0.rounded() == $0 ? String(Int($0)) : String(format: "%g", $0) } ?? "")
        _unit = State(initialValue: item.effectiveUnit)
        _notes = State(initialValue: item.effectiveNotes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.ingredientName)
                        .font(.body.weight(.semibold))
                    if !item.sourceMeals.isEmpty {
                        Text(item.sourceMeals)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Quantity") {
                    HStack {
                        TextField("Amount", text: $quantityText)
                            .keyboardType(.decimalPad)
                        TextField("Unit", text: $unit)
                            .textInputAutocapitalization(.never)
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Button {
                        showingLinker = true
                    } label: {
                        HStack {
                            Label(item.baseIngredientId == nil ? "Link to Ingredient" : "Re-link to Ingredient",
                                  systemImage: "link")
                            Spacer()
                            if let base = item.baseIngredientName, !base.isEmpty {
                                Text(base)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Catalog ingredient")
                } footer: {
                    if item.baseIngredientId == nil {
                        Text("Link this row to a canonical ingredient so smart-merge regen and brand preferences apply.")
                    } else {
                        Text("Linked to a canonical entry. Re-link to switch to a different one.")
                    }
                }
                if !item.isUserAdded && hasAnyOverride {
                    Section {
                        Button("Reset to auto", role: .destructive) {
                            Task { await resetOverrides() }
                        }
                    } footer: {
                        Text("Drops your edits and re-uses what the meal aggregation produced.")
                    }
                }
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .sheet(isPresented: $showingLinker) {
                IngredientLinkPickerSheet(item: item) { _ in
                    // Linker writes to the server + AppState; bounce
                    // the editor so the user reopens it on the live
                    // (now-linked) row.
                    dismiss()
                }
                .environment(appState)
            }
        }
    }

    private var hasAnyOverride: Bool {
        item.quantityOverride != nil || item.unitOverride != nil || item.notesOverride != nil
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let qty = Double(quantityText.trimmingCharacters(in: .whitespaces))
        let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        await appState.editGroceryItem(
            id: item.groceryItemId,
            quantity: qty.map { .set($0) },
            unit: trimmedUnit.isEmpty ? nil : .set(trimmedUnit),
            notes: trimmedNotes.isEmpty ? nil : .set(trimmedNotes)
        )
        dismiss()
    }

    private func resetOverrides() async {
        isSaving = true
        defer { isSaving = false }
        await appState.editGroceryItem(
            id: item.groceryItemId,
            quantity: .clear,
            unit: .clear,
            notes: .clear
        )
        dismiss()
    }
}
