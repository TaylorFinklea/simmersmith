import SwiftUI
import SimmerSmithKit

/// M28 — pantry item editor. Add a new item or edit an existing one.
///
/// Cadence picker drives the recurring auto-add. `none` makes the row
/// a pure staple (filtered from grocery, never auto-added). The other
/// options auto-add to weekly grocery on the chosen rhythm.
struct PantryItemEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: PantryItem?

    @State private var name: String = ""
    @State private var category: String = ""
    @State private var notes: String = ""
    @State private var isActive: Bool = true
    @State private var typicalQuantityText: String = ""
    @State private var typicalUnit: String = ""
    @State private var recurringCadence: String = "none"
    @State private var recurringQuantityText: String = ""
    @State private var recurringUnit: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    private let cadenceOptions: [(value: String, label: String)] = [
        ("none", "Don't auto-add"),
        ("weekly", "Weekly"),
        ("biweekly", "Every 2 weeks"),
        ("monthly", "Monthly"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Eggs)", text: $name)
                    TextField("Category (e.g. dairy)", text: $category)
                    Toggle("Active", isOn: $isActive)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    HStack {
                        TextField("Quantity", text: $typicalQuantityText)
                            .keyboardType(.decimalPad)
                        TextField("Unit", text: $typicalUnit)
                            .frame(maxWidth: 80)
                    }
                } header: {
                    Text("Typical purchase")
                } footer: {
                    Text("How you usually buy it (e.g. 50 lb bag of flour). Informational only — doesn't change grocery quantities.")
                }

                Section {
                    Picker("Auto-restock", selection: $recurringCadence) {
                        ForEach(cadenceOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    if recurringCadence != "none" {
                        HStack {
                            TextField("Quantity", text: $recurringQuantityText)
                                .keyboardType(.decimalPad)
                            TextField("Unit", text: $recurringUnit)
                                .frame(maxWidth: 80)
                        }
                    }
                } header: {
                    Text("Recurring")
                } footer: {
                    Text("When set, this item lands on each week's grocery list automatically (filtered from meal aggregation either way). Use weekly for things like \"5 dozen eggs every week\".")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(SMColor.destructive)
                    }
                }
            }
            .navigationTitle(item == nil ? "Add pantry item" : "Edit pantry item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: seed)
        }
    }

    private func seed() {
        guard let item else { return }
        name = item.stapleName
        category = item.category
        notes = item.notes
        isActive = item.isActive
        typicalQuantityText = item.typicalQuantity.map { String($0.cleanFormat) } ?? ""
        typicalUnit = item.typicalUnit
        recurringCadence = item.recurringCadence
        recurringQuantityText = item.recurringQuantity.map { String($0.cleanFormat) } ?? ""
        recurringUnit = item.recurringUnit
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        let typicalQty = Double(typicalQuantityText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        let recurringQty = recurringCadence == "none"
            ? nil
            : Double(recurringQuantityText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))

        if let existing = item {
            // PATCH path — only send what changed so partial saves
            // don't blank out fields on the server.
            var body = SimmerSmithAPIClient.PantryItemPatchBody()
            if trimmedName != existing.stapleName { body.stapleName = trimmedName }
            if category != existing.category { body.category = category }
            if notes != existing.notes { body.notes = notes }
            if isActive != existing.isActive { body.isActive = isActive }
            if typicalQty == nil && existing.typicalQuantity != nil {
                body.clearTypicalQuantity = true
            } else if let qty = typicalQty, qty != existing.typicalQuantity {
                body.typicalQuantity = qty
            }
            if typicalUnit != existing.typicalUnit { body.typicalUnit = typicalUnit }
            if recurringCadence != existing.recurringCadence { body.recurringCadence = recurringCadence }
            if recurringQty == nil && existing.recurringQuantity != nil {
                body.clearRecurringQuantity = true
            } else if let qty = recurringQty, qty != existing.recurringQuantity {
                body.recurringQuantity = qty
            }
            if recurringUnit != existing.recurringUnit { body.recurringUnit = recurringUnit }
            await appState.patchPantryItem(itemID: existing.pantryItemId, body: body)
        } else {
            await appState.addPantryItem(
                SimmerSmithAPIClient.PantryItemAddBody(
                    stapleName: trimmedName,
                    notes: notes,
                    isActive: isActive,
                    typicalQuantity: typicalQty,
                    typicalUnit: typicalUnit,
                    recurringQuantity: recurringQty,
                    recurringUnit: recurringUnit,
                    recurringCadence: recurringCadence,
                    category: category
                )
            )
        }
        dismiss()
    }
}

private extension Double {
    /// Trim trailing zeros from a decimal: 5.0 → "5", 5.25 → "5.25".
    var cleanFormat: String {
        if self.rounded() == self {
            return String(Int(self))
        }
        return String(format: "%.2f", self).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}
