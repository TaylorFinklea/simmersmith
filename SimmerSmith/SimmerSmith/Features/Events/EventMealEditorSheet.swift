import SwiftUI
import SimmerSmithKit

/// Add / edit a single event meal. Supports a saved-recipe link OR
/// free-text dish name; optional servings, notes, and an assignee
/// picked from the event's guest list (+ "Me / host" option).
struct EventMealEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let event: Event
    let meal: EventMeal?

    @State private var role: String = "side"
    @State private var recipeName: String = ""
    @State private var linkedRecipeID: String? = nil
    @State private var servingsText: String = ""
    @State private var notes: String = ""
    @State private var assignedGuestID: String? = nil
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private let roles = ["starter", "main", "side", "dessert", "beverage", "other"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Dish") {
                    Picker("Role", selection: $role) {
                        ForEach(roles, id: \.self) { r in
                            Text(r.capitalized).tag(r)
                        }
                    }
                    TextField("Dish name", text: $recipeName)
                    TextField("Servings (optional)", text: $servingsText)
                        .keyboardType(.numberPad)
                }

                Section {
                    Picker("From your recipes", selection: Binding(
                        get: { linkedRecipeID ?? "" },
                        set: { linkedRecipeID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("None — free text dish").tag("")
                        ForEach(appState.recipes.filter { !$0.archived }) { recipe in
                            Text(recipe.name).tag(recipe.recipeId)
                        }
                    }
                } header: {
                    Text("Link to saved recipe (optional)")
                } footer: {
                    Text("Pick a recipe and the grocery list will pull ingredients automatically. Free-text dishes don't contribute to the grocery roll-up yet.")
                }

                Section {
                    Picker("Assignee", selection: Binding(
                        get: { assignedGuestID ?? "" },
                        set: { assignedGuestID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Host (me)").tag("")
                        ForEach(event.attendees) { attendee in
                            Text("\(attendee.guest.name) is bringing it")
                                .tag(attendee.guestId)
                        }
                    }
                } header: {
                    Text("Who's bringing it?")
                } footer: {
                    Text("Pick a guest if they're providing this dish. Leave as \"Host\" for anything you're making yourself.")
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if meal != nil {
                    Section {
                        Button(role: .destructive) {
                            Task { await delete() }
                        } label: {
                            if isDeleting {
                                ProgressView()
                            } else {
                                Label("Remove from menu", systemImage: "trash")
                            }
                        }
                        .disabled(isDeleting)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(meal == nil ? "Add dish" : "Edit dish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(recipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .onAppear(perform: seed)
            .task {
                if appState.recipes.isEmpty {
                    await appState.refreshRecipes()
                }
            }
        }
    }

    private func seed() {
        guard let meal else { return }
        role = meal.role
        recipeName = meal.recipeName
        linkedRecipeID = meal.recipeId
        servingsText = meal.servings.map { String(Int($0)) } ?? ""
        notes = meal.notes
        assignedGuestID = meal.assignedGuestId
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let servings = Double(servingsText.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            if let meal {
                // Use clearAssignee when the user wants to unset.
                let clearing = meal.assignedGuestId != nil && assignedGuestID == nil
                _ = try await appState.updateEventMeal(
                    eventID: event.eventId,
                    mealID: meal.mealId,
                    role: role,
                    recipeID: linkedRecipeID,
                    recipeName: recipeName,
                    servings: servings,
                    notes: notes,
                    assignedGuestID: clearing ? nil : assignedGuestID,
                    clearAssignee: clearing
                )
            } else {
                _ = try await appState.addEventMeal(
                    eventID: event.eventId,
                    role: role,
                    recipeName: recipeName,
                    recipeID: linkedRecipeID,
                    servings: servings,
                    notes: notes,
                    assignedGuestID: assignedGuestID
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        guard let meal else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await appState.deleteEventMeal(eventID: event.eventId, mealID: meal.mealId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
