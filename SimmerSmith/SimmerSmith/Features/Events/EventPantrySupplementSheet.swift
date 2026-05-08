import SwiftUI
import SimmerSmithKit

/// M28 phase 2 — add or edit a pantry supplement on an event.
///
/// Supplements are additive: this is the *extra* quantity needed
/// beyond your normal pantry stock for this event. The recurring
/// pantry restock still fires for the week — the supplement adds
/// to the same grocery row via `event_quantity` attribution.
struct EventPantrySupplementSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let event: Event
    let supplement: EventPantrySupplement?

    @State private var pantryItemId: String = ""
    @State private var quantityText: String = ""
    @State private var unit: String = ""
    @State private var notes: String = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorMessage: String? = nil

    private var availablePantryItems: [PantryItem] {
        // When editing, the picker is disabled — just show the
        // current pantry item. When adding, exclude items that
        // already have a supplement on this event (one per pair).
        if let supplement {
            return appState.pantryItems.filter { $0.pantryItemId == supplement.pantryItemId }
        }
        let alreadyAttached = Set(event.pantrySupplements.map(\.pantryItemId))
        return appState.pantryItems.filter { !alreadyAttached.contains($0.pantryItemId) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Pantry item", selection: $pantryItemId) {
                        if availablePantryItems.isEmpty {
                            Text("No eligible pantry items").tag("")
                        }
                        ForEach(availablePantryItems) { item in
                            Text(item.stapleName).tag(item.pantryItemId)
                        }
                    }
                    .disabled(supplement != nil)
                } header: {
                    Text("Item")
                } footer: {
                    Text("One supplement per pantry item per event. If you need a different pantry item, add another supplement.")
                }

                Section {
                    HStack {
                        TextField("Extra quantity", text: $quantityText)
                            .keyboardType(.decimalPad)
                        TextField("Unit", text: $unit)
                            .frame(maxWidth: 80)
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Supplemental quantity")
                } footer: {
                    Text("This is the EXTRA you need on top of normal pantry stock — e.g. \"100 eggs for the brunch.\" Auto-applied to the linked week's grocery list when auto-merge is on.")
                }

                if let supplement {
                    Section {
                        Button(role: .destructive) {
                            Task { await delete(supplement) }
                        } label: {
                            if isDeleting {
                                ProgressView()
                            } else {
                                Label("Delete supplement", systemImage: "trash")
                            }
                        }
                        .disabled(isDeleting)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(SMColor.destructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle(supplement == nil ? "Add supplement" : "Edit supplement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .foregroundStyle(SMColor.ember)
                    .disabled(
                        isSaving ||
                        pantryItemId.isEmpty ||
                        Double(quantityText) ?? 0 <= 0
                    )
                }
            }
            .smithToolbar()
            .onAppear(perform: seed)
        }
    }

    private func seed() {
        if let supplement {
            pantryItemId = supplement.pantryItemId
            quantityText = supplement.quantity.rounded() == supplement.quantity
                ? String(Int(supplement.quantity))
                : String(format: "%.2f", supplement.quantity)
            unit = supplement.unit
            notes = supplement.notes
        } else if pantryItemId.isEmpty, let first = availablePantryItems.first {
            pantryItemId = first.pantryItemId
            // Default the unit from the pantry item's recurring/typical unit.
            unit = first.recurringUnit.isEmpty ? first.typicalUnit : first.recurringUnit
        }
    }

    private func save() async {
        guard let qty = Double(quantityText.replacingOccurrences(of: ",", with: ".")), qty > 0 else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            if let supplement {
                var body = SimmerSmithAPIClient.EventSupplementPatchBody()
                if qty != supplement.quantity { body.quantity = qty }
                if unit != supplement.unit { body.unit = unit }
                if notes != supplement.notes { body.notes = notes }
                _ = try await appState.patchEventSupplement(
                    eventID: event.eventId,
                    supplementID: supplement.supplementId,
                    body: body
                )
            } else {
                _ = try await appState.addEventSupplement(
                    eventID: event.eventId,
                    pantryItemID: pantryItemId,
                    quantity: qty,
                    unit: unit,
                    notes: notes
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ supplement: EventPantrySupplement) async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await appState.deleteEventSupplement(
                eventID: event.eventId,
                supplementID: supplement.supplementId
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
