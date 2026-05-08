import SwiftUI
import SimmerSmithKit

/// Sheet for adding a manually-entered grocery item to the current
/// week. The server marks these rows `is_user_added=true` so smart-
/// merge regeneration never deletes or rewrites them.
struct AddGroceryItemSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var quantityText: String = ""
    @State private var unit: String = ""
    @State private var notes: String = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name (e.g. paper towels)", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Quantity") {
                    HStack {
                        TextField("Amount", text: $quantityText)
                            .keyboardType(.decimalPad)
                        TextField("Unit (cup, pkg, ea)", text: $unit)
                            .textInputAutocapitalization(.never)
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Add to Grocery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { Task { await save() } }
                        .foregroundStyle(SMColor.ember)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .smithToolbar()
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let qty = Double(quantityText.trimmingCharacters(in: .whitespaces))
        await appState.addGroceryItem(
            name: name,
            quantity: qty,
            unit: unit,
            notes: notes
        )
        dismiss()
    }
}
