import SwiftUI
import SimmerSmithKit

/// Build 57 — small sheet for "Save leftovers to freezer" on a week
/// meal. Prefills the freezer item name from the meal's recipe name
/// and defaults the freeze date to today. The sheet writes a new
/// pantry row via the standard pantry API; we don't gate on a
/// "mark cooked" flow yet, the button is always available.
struct SaveLeftoversToFreezerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let meal: WeekMeal

    @State private var name: String = ""
    @State private var frozenAt: Date = Date()
    @State private var notes: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text("What's going in?")
                } footer: {
                    Text("Defaults to the meal name + \"leftovers\". Edit it if you want.")
                }

                Section {
                    DatePicker("Frozen on", selection: $frozenAt, displayedComponents: .date)
                } footer: {
                    Text("Defaults to today. Backdate this if the leftovers have been in there a while.")
                }

                Section {
                    TextField("Notes (e.g. \"2 servings\")", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Notes")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(SMColor.destructive)
                    }
                }
            }
            .navigationTitle("Save leftovers")
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
            .onAppear {
                if name.isEmpty {
                    let base = meal.recipeName.trimmingCharacters(in: .whitespaces)
                    name = base.isEmpty ? "Leftovers" : "\(base) leftovers"
                }
            }
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        await appState.addPantryItem(
            SimmerSmithAPIClient.PantryItemAddBody(
                stapleName: trimmed,
                notes: notes,
                isActive: true,
                recurringCadence: "none",
                categories: ["Freezer"],
                frozenAt: frozenAt
            )
        )
        dismiss()
    }
}
