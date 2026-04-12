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
    @State private var showingReviewQueue = false
    @State private var showingIngredientManager = false
    @State private var showingAISuggestionSheet = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: SMSpacing.md),
        GridItem(.flexible(), spacing: SMSpacing.md),
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SMColor.surface
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: SMSpacing.lg) {
                    searchBar
                    mealFilterChips
                    sortAndFilterControls

                    if isGeneratingSuggestion {
                        aiGeneratingBanner
                    }

                    if visibleRecipes.isEmpty {
                        emptyState
                    } else {
                        recipeGrid
                    }
                }
                .padding(.horizontal, SMSpacing.lg)
                .padding(.bottom, 80)
            }

            if !isSelectionMode {
                AIFloatingButton {
                    showingAISuggestionSheet = true
                }
                .padding(SMSpacing.xl)
            }
        }
        .navigationTitle("Recipes")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandToolbarBadge()
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        Task { await appState.refreshRecipes() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showingReviewQueue = true
                    } label: {
                        Label(reviewQueueButtonTitle, systemImage: "checklist")
                    }
                    Button {
                        showingIngredientManager = true
                    } label: {
                        Label("Manage ingredients", systemImage: "list.bullet")
                    }
                    Button {
                        showArchived.toggle()
                    } label: {
                        Label(showArchived ? "Hide archived" : "Show archived", systemImage: "archivebox")
                    }
                    Button {
                        isSelectionMode.toggle()
                        if !isSelectionMode {
                            selectedRecipeIDs.removeAll()
                        }
                    } label: {
                        Label(isSelectionMode ? "Done selecting" : "Select recipes", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editorContext = RecipeEditorSheetContext(
                            title: "New Recipe",
                            draft: RecipeDraft(name: "", mealType: mealFilter == .all ? "dinner" : mealFilter.rawValue)
                        )
                    } label: {
                        Label("New recipe", systemImage: "square.and.pencil")
                    }
                    Divider()
                    Button {
                        importLaunchMode = .url
                    } label: {
                        Label("Import from URL", systemImage: "link")
                    }
                    Button {
                        importLaunchMode = .camera
                    } label: {
                        Label("Scan from Camera", systemImage: "camera")
                    }
                    Button {
                        importLaunchMode = .photo
                    } label: {
                        Label("Import from Photo", systemImage: "photo")
                    }
                    Button {
                        importLaunchMode = .pdf
                    } label: {
                        Label("Import from PDF", systemImage: "doc.richtext")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(SMColor.primary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                selectionBar
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
        .sheet(isPresented: $showingReviewQueue) {
            IngredientReviewQueueView()
        }
        .sheet(isPresented: $showingAISuggestionSheet) {
            aiSuggestionSheet
        }
        .navigationDestination(isPresented: $showingIngredientManager) {
            IngredientsView()
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

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: SMSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SMColor.textTertiary)
                .font(.system(size: 16))

            TextField("Search recipes, tags, memories", text: $searchText)
                .font(SMFont.body)
                .foregroundStyle(SMColor.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SMColor.textTertiary)
                }
            }
        }
        .padding(.horizontal, SMSpacing.md)
        .padding(.vertical, SMSpacing.md)
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .padding(.top, SMSpacing.sm)
    }

    // MARK: - Meal Filter Chips

    private var mealFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SMSpacing.sm) {
                ForEach(RecipeMealFilter.allCases) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mealFilter = filter
                        }
                    } label: {
                        Text(filter.title)
                            .font(SMFont.label)
                            .foregroundStyle(mealFilter == filter ? SMColor.primary : SMColor.textSecondary)
                            .padding(.horizontal, SMSpacing.md)
                            .padding(.vertical, SMSpacing.sm)
                            .background(SMColor.surfaceCard)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(mealFilter == filter ? SMColor.primary : Color.clear, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Sort & Filter Controls

    private var sortAndFilterControls: some View {
        VStack(spacing: SMSpacing.sm) {
            HStack(spacing: SMSpacing.sm) {
                // Sort picker
                Menu {
                    ForEach(RecipeSortOption.allCases) { option in
                        Button {
                            sortOption = option
                        } label: {
                            HStack {
                                Text(option.title)
                                if sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: SMSpacing.xs) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12))
                        Text(sortOption.title)
                            .font(SMFont.caption)
                    }
                    .foregroundStyle(SMColor.textSecondary)
                    .padding(.horizontal, SMSpacing.md)
                    .padding(.vertical, SMSpacing.sm)
                    .background(SMColor.surfaceCard)
                    .clipShape(Capsule())
                }

                // Cuisine picker
                Menu {
                    Button {
                        selectedCuisine = ""
                    } label: {
                        HStack {
                            Text("All cuisines")
                            if selectedCuisine.isEmpty {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    ForEach(appState.recipeMetadata?.cuisines ?? []) { cuisine in
                        Button {
                            selectedCuisine = cuisine.name
                        } label: {
                            HStack {
                                Text(cuisine.name)
                                if selectedCuisine == cuisine.name {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: SMSpacing.xs) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 12))
                        Text(selectedCuisine.isEmpty ? "Cuisine" : selectedCuisine)
                            .font(SMFont.caption)
                    }
                    .foregroundStyle(selectedCuisine.isEmpty ? SMColor.textSecondary : SMColor.primary)
                    .padding(.horizontal, SMSpacing.md)
                    .padding(.vertical, SMSpacing.sm)
                    .background(SMColor.surfaceCard)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(selectedCuisine.isEmpty ? Color.clear : SMColor.primary, lineWidth: 1)
                    )
                }

                Spacer()
            }

            // Tag chips
            if let metadata = appState.recipeMetadata, !metadata.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SMSpacing.sm) {
                        ForEach(metadata.tags) { tag in
                            Button {
                                toggleTag(tag.name)
                            } label: {
                                Text(tag.name)
                                    .font(SMFont.caption)
                                    .foregroundStyle(selectedTags.contains(tag.name) ? SMColor.primary : SMColor.textSecondary)
                                    .padding(.horizontal, SMSpacing.md)
                                    .padding(.vertical, SMSpacing.xs)
                                    .background(SMColor.surfaceCard)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(selectedTags.contains(tag.name) ? SMColor.primary : Color.clear, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - AI Generating Banner

    private var aiGeneratingBanner: some View {
        HStack(spacing: SMSpacing.md) {
            ProgressView()
                .tint(SMColor.aiPurple)
            Text("Generating AI suggestion draft...")
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SMSpacing.lg)
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: SMSpacing.lg) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(SMColor.textTertiary)
            Text("No Recipes")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
            Text(emptyStateMessage)
                .font(SMFont.body)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SMSpacing.xxl * 2)
    }

    // MARK: - Recipe Grid

    private var recipeGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: SMSpacing.md) {
            ForEach(Array(visibleRecipes.enumerated()), id: \.element.id) { index, recipe in
                if isSelectionMode {
                    Button {
                        toggleSelection(for: recipe)
                    } label: {
                        RecipeGridCell(
                            recipe: recipe,
                            gradientIndex: index,
                            isSelected: selectedRecipeIDs.contains(recipe.recipeId)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        RecipeDetailView(recipeID: recipe.recipeId)
                    } label: {
                        RecipeGridCell(
                            recipe: recipe,
                            gradientIndex: index,
                            isSelected: false
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Selection Bar

    private var selectionBar: some View {
        HStack {
            Text("\(selectedRecipeIDs.count) selected")
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textSecondary)
            Spacer()
            Button {
                assignmentContext = RecipeAssignmentSheetContext(recipes: selectedRecipes)
            } label: {
                Text("Add to Week")
                    .font(SMFont.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, SMSpacing.lg)
                    .padding(.vertical, SMSpacing.sm)
                    .background(selectedRecipeIDs.isEmpty ? SMColor.textTertiary : SMColor.primary)
                    .clipShape(Capsule())
            }
            .disabled(selectedRecipeIDs.isEmpty)
        }
        .padding(.horizontal, SMSpacing.lg)
        .padding(.vertical, SMSpacing.md)
        .background(SMColor.surfaceElevated)
    }

    // MARK: - AI Suggestion Sheet

    private var aiSuggestionSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        Text("Let AI suggest a new recipe based on your taste preferences and recent meals.")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                            .listRowBackground(SMColor.surfaceCard)
                    }

                    Section("Choose a goal") {
                        ForEach(RecipeSuggestionGoal.allCases) { goal in
                            Button {
                                showingAISuggestionSheet = false
                                Task { await generateSuggestion(goal) }
                            } label: {
                                HStack {
                                    Text(goal.title)
                                        .font(SMFont.body)
                                        .foregroundStyle(SMColor.textPrimary)
                                    Spacer()
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(SMColor.aiPurple)
                                }
                            }
                            .disabled(isGeneratingSuggestion || appState.recipes.isEmpty)
                            .listRowBackground(SMColor.surfaceCard)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(SMColor.surface)
            }
            .navigationTitle("AI Suggestion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAISuggestionSheet = false
                    }
                    .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Data & Logic

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

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
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

    private var reviewQueueButtonTitle: String {
        let reviewCount = appState.recipes.reduce(into: 0) { count, recipe in
            count += recipe.ingredients.filter { $0.resolutionStatus == "unresolved" || $0.resolutionStatus == "suggested" }.count
        }
        if reviewCount == 0 {
            return "Review queue"
        }
        return "Review queue (\(reviewCount))"
    }
}

// MARK: - Recipe Grid Cell

private struct RecipeGridCell: View {
    let recipe: RecipeSummary
    let gradientIndex: Int
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RecipeCard(recipe: recipe, gradientIndex: gradientIndex)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(SMColor.success)
                    .background(Circle().fill(SMColor.surface).padding(2))
                    .padding(SMSpacing.sm)
            }
        }
    }
}
