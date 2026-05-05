import SwiftUI
import SimmerSmithKit

/// M26 Phase 2 — manage sides on a meal.
///
/// Reads the currently displayed meal from `appState.currentWeek` so a
/// successful add/delete (which fetches the whole week) reactively
/// refreshes this view. Editing a side opens an inline `SideEditorSheet`
/// for rename + recipe-link changes.
struct MealSidesSheet: View {
    let weekID: String
    let mealID: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var newSideName: String = ""
    @State private var newSideRecipeID: String? = nil
    @State private var editingSide: WeekMealSide? = nil
    @State private var isWorking = false
    @State private var errorMessage: String? = nil

    private var currentMeal: WeekMeal? {
        appState.currentWeek?.meals.first(where: { $0.mealId == mealID })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let meal = currentMeal {
                    Section {
                        Text(meal.recipeName)
                            .font(SMFont.headline)
                            .foregroundStyle(SMColor.textPrimary)
                    } header: {
                        Text("Meal")
                    }

                    Section {
                        if meal.sides.isEmpty {
                            Text("No sides yet — add one below.")
                                .foregroundStyle(SMColor.textTertiary)
                        } else {
                            ForEach(meal.sides) { side in
                                Button {
                                    editingSide = side
                                } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: SMSpacing.xs) {
                                            Text(side.name)
                                                .font(SMFont.subheadline)
                                                .foregroundStyle(SMColor.textPrimary)
                                            if let recipeName = side.recipeName, !recipeName.isEmpty {
                                                Label(recipeName, systemImage: "book.closed")
                                                    .font(SMFont.caption)
                                                    .foregroundStyle(SMColor.textSecondary)
                                            } else {
                                                Text("No recipe linked — won't add to grocery")
                                                    .font(SMFont.caption)
                                                    .foregroundStyle(SMColor.textTertiary)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(SMColor.textTertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await delete(side) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Sides")
                    }

                    Section {
                        TextField("Side name (e.g. Garlic bread)", text: $newSideName)
                        Picker("Link recipe (optional)", selection: $newSideRecipeID) {
                            Text("No recipe").tag(String?.none)
                            ForEach(appState.recipes) { recipe in
                                Text(recipe.name).tag(String?.some(recipe.recipeId))
                            }
                        }
                        Button {
                            Task { await addSide() }
                        } label: {
                            if isWorking {
                                ProgressView()
                            } else {
                                Label("Add side", systemImage: "plus.circle.fill")
                            }
                        }
                        .disabled(
                            isWorking ||
                            newSideName.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                    } header: {
                        Text("Add a side")
                    } footer: {
                        Text("Sides with a linked recipe contribute their ingredients to the grocery list, scaled by this meal's serving size.")
                    }
                } else {
                    ContentUnavailableView(
                        "Meal not found",
                        systemImage: "questionmark.circle",
                        description: Text("This meal may have been removed.")
                    )
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(SMColor.destructive)
                    }
                }
            }
            .navigationTitle("Sides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingSide) { side in
                SideEditorSheet(weekID: weekID, mealID: mealID, side: side)
            }
        }
    }

    private func addSide() async {
        let trimmed = newSideName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await appState.addMealSide(
                weekID: weekID,
                mealID: mealID,
                name: trimmed,
                recipeID: newSideRecipeID
            )
            newSideName = ""
            newSideRecipeID = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ side: WeekMealSide) async {
        do {
            _ = try await appState.deleteMealSide(
                weekID: weekID, mealID: mealID, sideID: side.sideId
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Inline editor for a single side — rename + change recipe link.
private struct SideEditorSheet: View {
    let weekID: String
    let mealID: String
    let side: WeekMealSide

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var recipeID: String?
    @State private var isWorking = false
    @State private var errorMessage: String? = nil

    @State private var aiPrompt: String = ""
    @State private var isGeneratingAI = false
    @State private var pendingDraft: RecipeDraft? = nil

    init(weekID: String, mealID: String, side: WeekMealSide) {
        self.weekID = weekID
        self.mealID = mealID
        self.side = side
        _name = State(initialValue: side.name)
        _recipeID = State(initialValue: side.recipeId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section("Recipe") {
                    Picker("Linked recipe", selection: $recipeID) {
                        Text("No recipe").tag(String?.none)
                        ForEach(appState.recipes) { recipe in
                            Text(recipe.name).tag(String?.some(recipe.recipeId))
                        }
                    }
                }

                // M29 build 53 — generate a recipe draft for this side
                // via AI. Routes through `RecipeDraftReviewSheet` so
                // the user can refine + review before anything saves.
                Section {
                    TextField("Hint (optional, e.g. \"with parmesan\")", text: $aiPrompt, axis: .vertical)
                        .lineLimit(1...3)
                    Button {
                        Task { await generateRecipeWithAI() }
                    } label: {
                        HStack {
                            if isGeneratingAI {
                                ProgressView()
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(isGeneratingAI ? "Drafting…" : "Generate recipe with AI")
                        }
                    }
                    .disabled(
                        isGeneratingAI ||
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                } header: {
                    Text("Or have AI write a recipe")
                } footer: {
                    Text("Draft opens in a review sheet — refine or edit before saving. Nothing lands in your recipes library until you tap Save there.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(SMColor.destructive)
                    }
                }
            }
            .navigationTitle("Edit side")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(
                            isWorking ||
                            name.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
            }
            .sheet(item: $pendingDraft) { draft in
                RecipeDraftReviewSheet(
                    initialDraft: draft,
                    refineContextHint: "a side dish for the meal",
                    onSave: { saved in
                        Task { await linkSavedDraftToSide(saved) }
                    }
                )
            }
        }
    }

    private func generateRecipeWithAI() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Persist the side name change first so the backend route
        // sees the correct dish name. Cheap PATCH — no grocery
        // ripple if the name didn't actually change.
        if trimmed != side.name {
            var body = SimmerSmithAPIClient.WeekMealSidePatchBody()
            body.name = trimmed
            do {
                _ = try await appState.patchMealSide(
                    weekID: weekID, mealID: mealID, sideID: side.sideId, body: body
                )
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        isGeneratingAI = true
        defer { isGeneratingAI = false }
        errorMessage = nil
        do {
            let draft = try await appState.apiClient.generateSideRecipeDraft(
                weekID: weekID,
                mealID: mealID,
                sideID: side.sideId,
                prompt: aiPrompt,
                servings: 0
            )
            pendingDraft = draft
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func linkSavedDraftToSide(_ saved: RecipeSummary) async {
        var body = SimmerSmithAPIClient.WeekMealSidePatchBody()
        body.recipeId = saved.recipeId
        do {
            _ = try await appState.patchMealSide(
                weekID: weekID, mealID: mealID, sideID: side.sideId, body: body
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        recipeID = saved.recipeId
        await appState.refreshRecipes()
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        isWorking = true
        defer { isWorking = false }
        var body = SimmerSmithAPIClient.WeekMealSidePatchBody()
        if trimmed != side.name { body.name = trimmed }
        if recipeID != side.recipeId {
            if let newID = recipeID {
                body.recipeId = newID
            } else {
                body.clearRecipe = true
            }
        }
        do {
            _ = try await appState.patchMealSide(
                weekID: weekID, mealID: mealID, sideID: side.sideId, body: body
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
