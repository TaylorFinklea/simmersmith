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

    // M26 Phase 4 — AI recipe generation for an existing event meal.
    @State private var aiPrompt: String = ""
    @State private var isGeneratingAI = false
    @State private var aiToast: String? = nil
    // M29 build 53 — review draft before commit.
    @State private var pendingDraft: PendingDraft? = nil

    private struct PendingDraft: Identifiable {
        let id = UUID()
        let draft: RecipeDraft
        let mealId: String
        let contextHint: String
    }

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

                if let meal {
                    Section {
                        TextField("Hint (optional, e.g. \"gluten-free\")", text: $aiPrompt, axis: .vertical)
                            .lineLimit(1...3)
                        Button {
                            Task { await generateRecipeWithAI(for: meal) }
                        } label: {
                            HStack {
                                if isGeneratingAI {
                                    ProgressView()
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isGeneratingAI ? "Generating…" : "Generate recipe with AI")
                            }
                        }
                        .disabled(isGeneratingAI)
                        if let aiToast {
                            Text(aiToast)
                                .font(.footnote)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    } header: {
                        Text("Or have AI write a recipe")
                    } footer: {
                        Text("AI uses the dish name + guest constraints. The new recipe lands in your library and gets linked here automatically.")
                    }
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
            .sheet(item: $pendingDraft) { pending in
                RecipeDraftReviewSheet(
                    initialDraft: pending.draft,
                    refineContextHint: pending.contextHint,
                    onSave: { saved in
                        Task { await handleSavedDraft(saved, for: pending.mealId) }
                    }
                )
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

    /// M29 build 53 — fetch the AI draft and present the review
    /// sheet. The draft does NOT persist until the user taps Save in
    /// the review sheet (or its hand-edit path). On save, the
    /// `onSave` callback wires `recipeId` onto the event meal.
    private func generateRecipeWithAI(for meal: EventMeal) async {
        isGeneratingAI = true
        defer { isGeneratingAI = false }
        aiToast = nil
        errorMessage = nil
        let servings = Int(servingsText.trimmingCharacters(in: .whitespaces)) ?? 0
        do {
            let draft = try await appState.apiClient.generateEventMealRecipe(
                eventID: event.eventId,
                mealID: meal.mealId,
                prompt: aiPrompt,
                servings: servings
            )
            pendingDraft = PendingDraft(
                draft: draft,
                mealId: meal.mealId,
                contextHint: "an event meal for \"\(event.name)\""
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Called from the review sheet's `onSave`. By this point the
    /// recipe is persisted; we just need to attach it to the event
    /// meal. Refreshes recipes so the picker shows the new entry.
    private func handleSavedDraft(_ saved: RecipeSummary, for mealId: String) async {
        let servings = Int(servingsText.trimmingCharacters(in: .whitespaces)) ?? 0
        do {
            _ = try await appState.updateEventMeal(
                eventID: event.eventId,
                mealID: mealId,
                role: role,
                recipeID: saved.recipeId,
                recipeName: recipeName,
                servings: servings > 0 ? Double(servings) : nil,
                notes: notes,
                assignedGuestID: assignedGuestID,
                clearAssignee: false
            )
            linkedRecipeID = saved.recipeId
            aiToast = "Linked to new recipe \"\(saved.name)\"."
            await appState.refreshRecipes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
