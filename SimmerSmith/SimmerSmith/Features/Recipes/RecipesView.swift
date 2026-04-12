import SwiftUI
import SimmerSmithKit

struct RecipesView: View {
    @Environment(AppState.self) private var appState

    @State private var searchText = ""
    @State private var selectedMealType: String = ""
    @State private var importLaunchMode: RecipeImportLaunchMode?
    @State private var editorContext: RecipeEditorSheetContext?
    @State private var isGeneratingSuggestion = false
    @State private var suggestionErrorMessage: String?
    @State private var showingAISuggestionSheet = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SMColor.surface
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: SMSpacing.xl) {
                    searchBar
                    mealTypeFilterPills

                    if isGeneratingSuggestion {
                        aiGeneratingBanner
                    }

                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchResults
                    } else {
                        editorialSections
                    }
                }
                .padding(.bottom, 80)
            }

            AIFloatingButton {
                showingAISuggestionSheet = true
            }
            .padding(SMSpacing.xl)
        }
        .navigationTitle("Recipes")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editorContext = RecipeEditorSheetContext(
                            title: "New Recipe",
                            draft: RecipeDraft(name: "", mealType: "dinner")
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
                        Label("Import from Camera", systemImage: "camera")
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
        .sheet(item: $importLaunchMode) { mode in
            RecipeImportView(preferredLaunchMode: mode) { draft in
                editorContext = RecipeEditorSheetContext(title: "Imported Recipe", draft: draft)
            }
        }
        .sheet(item: $editorContext) { context in
            RecipeEditorView(title: context.title, initialDraft: context.draft) { _ in }
        }
        .sheet(isPresented: $showingAISuggestionSheet) {
            aiSuggestionSheet
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
            HStack(spacing: SMSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SMColor.textTertiary)
                    .font(.system(size: 16))

                TextField("Search recipes, tags, memories", text: $searchText)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isSearchFocused)

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

            if isSearchFocused {
                Button("Cancel") {
                    searchText = ""
                    isSearchFocused = false
                }
                .font(SMFont.body)
                .foregroundStyle(SMColor.primary)
            }
        }
        .padding(.horizontal, SMSpacing.lg)
        .padding(.top, SMSpacing.sm)
    }

    // MARK: - Meal Type Filter Pills

    private static let mealTypeFilters: [(label: String, value: String)] = [
        ("All", ""),
        ("Breakfast", "breakfast"),
        ("Lunch", "lunch"),
        ("Dinner", "dinner"),
        ("Snack", "snack"),
    ]

    private var mealTypeFilterPills: some View {
        HStack(spacing: SMSpacing.sm) {
            ForEach(Self.mealTypeFilters, id: \.value) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedMealType = filter.value
                    }
                } label: {
                    Text(filter.label)
                        .font(SMFont.caption)
                        .foregroundStyle(selectedMealType == filter.value ? SMColor.primary : SMColor.textSecondary)
                        .padding(.horizontal, SMSpacing.md)
                        .padding(.vertical, SMSpacing.sm)
                        .background(SMColor.surfaceCard)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(selectedMealType == filter.value ? SMColor.primary : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SMSpacing.lg)
    }

    // MARK: - Search Results

    private var searchResults: some View {
        let results = filteredSearchResults
        return Group {
            if results.isEmpty {
                emptySearchState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, recipe in
                        NavigationLink {
                            RecipeDetailView(recipeID: recipe.recipeId)
                        } label: {
                            RecipeListRow(recipe: recipe, gradientIndex: index)
                        }
                        .buttonStyle(.plain)

                        if index < results.count - 1 {
                            Divider()
                                .foregroundStyle(SMColor.divider)
                        }
                    }
                }
                .padding(.horizontal, SMSpacing.lg)
            }
        }
    }

    // MARK: - Editorial Sections

    private var editorialSections: some View {
        VStack(spacing: SMSpacing.xl) {
            // 1. Tonight's Dinner hero
            if let hero = tonightsDinner {
                VStack(spacing: SMSpacing.sm) {
                    sectionHeader("Tonight's Dinner")

                    NavigationLink {
                        RecipeDetailView(recipeID: hero.recipeId)
                    } label: {
                        HeroRecipeCard(recipe: hero)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, SMSpacing.lg)
                }
            }

            // 2. This Week horizontal scroll
            if !thisWeekRecipes.isEmpty {
                VStack(spacing: SMSpacing.sm) {
                    sectionHeader("This Week")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SMSpacing.md) {
                            ForEach(Array(thisWeekRecipes.enumerated()), id: \.element.id) { index, recipe in
                                NavigationLink {
                                    RecipeDetailView(recipeID: recipe.recipeId)
                                } label: {
                                    CompactRecipeCard(recipe: recipe, gradientIndex: index)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, SMSpacing.lg)
                    }
                }
            }

            // 3. Favorites horizontal scroll
            if !favoriteRecipes.isEmpty {
                VStack(spacing: SMSpacing.sm) {
                    sectionHeader("Favorites")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SMSpacing.md) {
                            ForEach(Array(favoriteRecipes.enumerated()), id: \.element.id) { index, recipe in
                                NavigationLink {
                                    RecipeDetailView(recipeID: recipe.recipeId)
                                } label: {
                                    CompactRecipeCard(recipe: recipe, gradientIndex: index + 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, SMSpacing.lg)
                    }
                }
            }

            // 4. Recently Added vertical list
            if !recentlyAddedRecipes.isEmpty {
                VStack(spacing: SMSpacing.sm) {
                    sectionHeader("Recently Added")

                    LazyVStack(spacing: 0) {
                        ForEach(Array(recentlyAddedRecipes.enumerated()), id: \.element.id) { index, recipe in
                            NavigationLink {
                                RecipeDetailView(recipeID: recipe.recipeId)
                            } label: {
                                RecipeListRow(recipe: recipe, gradientIndex: index)
                            }
                            .buttonStyle(.plain)

                            if index < recentlyAddedRecipes.count - 1 {
                                Divider()
                                    .foregroundStyle(SMColor.divider)
                            }
                        }
                    }
                    .padding(.horizontal, SMSpacing.lg)
                }
            }

            // 5. All Recipes vertical list
            if !allRecipes.isEmpty {
                VStack(spacing: SMSpacing.sm) {
                    sectionHeader("All Recipes")

                    LazyVStack(spacing: 0) {
                        ForEach(Array(allRecipes.enumerated()), id: \.element.id) { index, recipe in
                            NavigationLink {
                                RecipeDetailView(recipeID: recipe.recipeId)
                            } label: {
                                RecipeListRow(recipe: recipe, gradientIndex: index)
                            }
                            .buttonStyle(.plain)

                            if index < allRecipes.count - 1 {
                                Divider()
                                    .foregroundStyle(SMColor.divider)
                            }
                        }
                    }
                    .padding(.horizontal, SMSpacing.lg)
                }
            }

            // Empty state when there are no recipes at all
            if allRecipes.isEmpty {
                emptyState
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
            Spacer()
        }
        .padding(.horizontal, SMSpacing.lg)
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
        .padding(.horizontal, SMSpacing.lg)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: SMSpacing.lg) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(SMColor.textTertiary)
            Text("No Recipes")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
            Text("Create a recipe or import one from a URL to start planning.")
                .font(SMFont.body)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SMSpacing.xxl * 2)
    }

    private var emptySearchState: some View {
        VStack(spacing: SMSpacing.lg) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(SMColor.textTertiary)
            Text("No Results")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
            Text("Try a different search term.")
                .font(SMFont.body)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SMSpacing.xxl * 2)
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

    // MARK: - Data

    private var tonightsDinner: RecipeSummary? {
        // Try to find tonight's dinner from the current week
        if let week = appState.currentWeek {
            let todayDinner = week.meals.first {
                Calendar.current.isDateInToday($0.mealDate) && $0.slot.lowercased() == "dinner"
            }
            if let recipeId = todayDinner?.recipeId,
               let recipe = appState.recipes.first(where: { $0.recipeId == recipeId }) {
                return recipe
            }
        }
        // Fall back to the most recent favorite
        let favs = appState.recipes.filter { $0.favorite && !$0.archived }
        return favs.first
    }

    private var thisWeekRecipes: [RecipeSummary] {
        guard let week = appState.currentWeek else { return [] }
        let ids = Set(week.meals.compactMap(\.recipeId))
        return appState.recipes.filter { ids.contains($0.recipeId) }
    }

    private var favoriteRecipes: [RecipeSummary] {
        appState.recipes.filter { $0.favorite && !$0.archived }
    }

    private var recentlyAddedRecipes: [RecipeSummary] {
        appState.recipes
            .filter { !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(8)
            .map { $0 }
    }

    private var allRecipes: [RecipeSummary] {
        appState.recipes
            .filter { !$0.archived }
            .filter { matchesMealType($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredSearchResults: [RecipeSummary] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSearch.isEmpty else { return [] }

        return appState.recipes
            .filter { !$0.archived }
            .filter { matchesMealType($0) }
            .filter { recipe in
                [
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
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func matchesMealType(_ recipe: RecipeSummary) -> Bool {
        guard !selectedMealType.isEmpty else { return true }
        return recipe.mealType.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(selectedMealType) == .orderedSame
    }

    // MARK: - Actions

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
}
