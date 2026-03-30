import SwiftUI
import SimmerSmithKit

struct RecipesView: View {
    @Environment(AppState.self) private var appState

    @State private var searchText = ""
    @State private var mealFilter: RecipeMealFilter = .dinner
    @State private var sortOption: RecipeSortOption = .lastUsed
    @State private var selectedCuisine = ""
    @State private var selectedTags: Set<String> = []
    @State private var showArchived = false
    @State private var importLaunchMode: RecipeImportLaunchMode?
    @State private var isSelectionMode = false
    @State private var selectedRecipeIDs: Set<String> = []
    @State private var editorContext: RecipeEditorSheetContext?
    @State private var assignmentContext: RecipeAssignmentSheetContext?
    @State private var isGeneratingSuggestion = false
    @State private var suggestionErrorMessage: String?

    var body: some View {
        List {
            filterSection

            if isGeneratingSuggestion {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Generating AI suggestion draft…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if visibleRecipes.isEmpty {
                ContentUnavailableView(
                    "No Recipes",
                    systemImage: "book.closed",
                    description: Text(emptyStateMessage)
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleRecipes) { recipe in
                    if isSelectionMode {
                        Button {
                            toggleSelection(for: recipe)
                        } label: {
                            RecipeRow(recipe: recipe, isSelected: selectedRecipeIDs.contains(recipe.recipeId))
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            RecipeDetailView(recipeID: recipe.recipeId)
                        } label: {
                            RecipeRow(recipe: recipe, isSelected: false)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Recipes")
        .searchable(text: $searchText, prompt: "Search recipes, tags, memories")
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandToolbarBadge()
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu("Organize") {
                    Button("Refresh") {
                        Task { await appState.refreshRecipes() }
                    }
                    Button(showArchived ? "Hide archived" : "Show archived") {
                        showArchived.toggle()
                    }
                    Button(isSelectionMode ? "Done selecting" : "Select recipes") {
                        isSelectionMode.toggle()
                        if !isSelectionMode {
                            selectedRecipeIDs.removeAll()
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Create") {
                    Button("New recipe") {
                        editorContext = RecipeEditorSheetContext(
                            title: "New Recipe",
                            draft: RecipeDraft(name: "", mealType: mealFilter == .all ? "dinner" : mealFilter.rawValue)
                        )
                    }
                    Divider()
                    Button("Import from URL") { importLaunchMode = .url }
                    Button("Scan from Camera") { importLaunchMode = .camera }
                    Button("Import from Photo") { importLaunchMode = .photo }
                    Button("Import from PDF") { importLaunchMode = .pdf }
                    Divider()
                    Menu("AI Suggestion Draft") {
                        ForEach(RecipeSuggestionGoal.allCases) { goal in
                            Button(goal.title) {
                                Task { await generateSuggestion(goal) }
                            }
                            .disabled(isGeneratingSuggestion || appState.recipes.isEmpty)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                HStack {
                    Text("\(selectedRecipeIDs.count) selected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add to Week") {
                        assignmentContext = RecipeAssignmentSheetContext(recipes: selectedRecipes)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRecipeIDs.isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.thinMaterial)
            }
        }
        .sheet(item: $importLaunchMode) { mode in
            RecipeImportView(preferredLaunchMode: mode) { draft in
                editorContext = RecipeEditorSheetContext(title: "Imported Recipe", draft: draft)
            }
        }
        .sheet(item: $editorContext) { context in
            RecipeEditorView(title: context.title, initialDraft: context.draft) { savedRecipe in
                if isSelectionMode {
                    selectedRecipeIDs.insert(savedRecipe.recipeId)
                }
            }
        }
        .sheet(item: $assignmentContext) { context in
            RecipeWeekAssignmentView(recipes: context.recipes)
        }
        .alert("AI Suggestion Failed", isPresented: Binding(
            get: { suggestionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    suggestionErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                suggestionErrorMessage = nil
            }
        } message: {
            Text(suggestionErrorMessage ?? "The suggestion draft could not be created.")
        }
        .task {
            if appState.recipes.isEmpty {
                await appState.refreshRecipes()
            } else if appState.recipeMetadata == nil {
                await appState.refreshRecipeMetadata()
            }
        }
    }

    private var selectedRecipes: [RecipeSummary] {
        visibleRecipes.filter { selectedRecipeIDs.contains($0.recipeId) }
    }

    private var emptyStateMessage: String {
        if !searchText.isEmpty {
            return "Try a different search term or meal filter."
        }
        if showArchived {
            return "Add a recipe or restore one from the library."
        }
        return "Create a recipe or import one from a URL to start planning."
    }

    private var visibleRecipes: [RecipeSummary] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = appState.recipes.filter { recipe in
            let matchesArchive = showArchived || !recipe.archived
            let matchesMealType = mealFilter.matches(recipe)
            let matchesSearch: Bool
            if normalizedSearch.isEmpty {
                matchesSearch = true
            } else {
                matchesSearch = [
                    recipe.name,
                    recipe.tags.joined(separator: " "),
                    recipe.cuisine,
                    recipe.sourceLabel,
                    recipe.notes,
                    recipe.memories,
                    recipe.ingredients.map(\.ingredientName).joined(separator: " "),
                ]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(normalizedSearch)
            }
            let matchesCuisine = selectedCuisine.isEmpty || recipe.cuisine.localizedCaseInsensitiveCompare(selectedCuisine) == .orderedSame
            let recipeTagSet = Set(recipe.tags.map { $0.lowercased() })
            let matchesTags = selectedTags.isEmpty || selectedTags.allSatisfy { recipeTagSet.contains($0.lowercased()) }
            return matchesArchive && matchesMealType && matchesSearch && matchesCuisine && matchesTags
        }

        return filtered.sorted(by: recipeComparator)
    }

    private func recipeComparator(lhs: RecipeSummary, rhs: RecipeSummary) -> Bool {
        switch sortOption {
        case .lastUsed:
            if lhs.sortRecencyBucket != rhs.sortRecencyBucket {
                return lhs.sortRecencyBucket < rhs.sortRecencyBucket
            }
            if lhs.favorite != rhs.favorite {
                return lhs.favorite && !rhs.favorite
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .favorites:
            if lhs.sortFavoriteBucket != rhs.sortFavoriteBucket {
                return lhs.sortFavoriteBucket < rhs.sortFavoriteBucket
            }
            if lhs.sortRecencyBucket != rhs.sortRecencyBucket {
                return lhs.sortRecencyBucket < rhs.sortRecencyBucket
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .name:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .cuisine:
            let lhsCuisine = lhs.cuisine.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsCuisine = rhs.cuisine.trimmingCharacters(in: .whitespacesAndNewlines)
            if lhsCuisine != rhsCuisine {
                return lhsCuisine.localizedCaseInsensitiveCompare(rhsCuisine) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func toggleSelection(for recipe: RecipeSummary) {
        if selectedRecipeIDs.contains(recipe.recipeId) {
            selectedRecipeIDs.remove(recipe.recipeId)
        } else {
            selectedRecipeIDs.insert(recipe.recipeId)
        }
    }

    private func generateSuggestion(_ goal: RecipeSuggestionGoal) async {
        suggestionErrorMessage = nil
        isGeneratingSuggestion = true
        defer { isGeneratingSuggestion = false }

        do {
            let aiDraft = try await appState.generateRecipeSuggestionDraft(goal: goal.title)
            editorContext = RecipeEditorSheetContext(title: "\(goal.title) Suggestion", draft: aiDraft.draft)
        } catch {
            suggestionErrorMessage = error.localizedDescription
        }
    }

    private var filterSection: some View {
        Section {
            Picker("Meal type", selection: $mealFilter) {
                ForEach(RecipeMealFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            Picker("Sort", selection: $sortOption) {
                ForEach(RecipeSortOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Picker("Cuisine", selection: $selectedCuisine) {
                Text("All cuisines").tag("")
                ForEach(appState.recipeMetadata?.cuisines ?? []) { cuisine in
                    Text(cuisine.name).tag(cuisine.name)
                }
            }

            if let metadata = appState.recipeMetadata, !metadata.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(metadata.tags) { tag in
                            Button(tag.name) {
                                toggleTag(tag.name)
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedTags.contains(tag.name) ? .green : .secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }
}

private struct RecipeRow: View {
    let recipe: RecipeSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(recipe.name)
                        .font(.body.weight(.medium))
                    if recipe.favorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                    if recipe.isVariant {
                        Label("Variant", systemImage: "square.on.square")
                            .font(.caption)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    }
                }

                if !recipe.subtitleFragments.isEmpty {
                    Text(recipe.subtitleFragments.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(recipe.usageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !recipe.tags.isEmpty {
                    Text(recipe.tagSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if recipe.variantCount > 0 {
                Text("\(recipe.variantCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .contentShape(Rectangle())
    }
}
