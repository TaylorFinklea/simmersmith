import SwiftUI
import SimmerSmithKit

struct RecipesView: View {
    @Environment(AppState.self) private var appState
    @Environment(AIAssistantCoordinator.self) private var aiCoordinator

    @State private var searchText = ""
    @State private var selectedMealType: String = ""
    @State private var selectedDifficulty: DifficultyFilter = .any
    @State private var importLaunchMode: RecipeImportLaunchMode?
    @State private var editorContext: RecipeEditorSheetContext?
    @State private var isGeneratingSuggestion = false
    @State private var suggestionErrorMessage: String?
    @State private var showingAISuggestionSheet = false
    @State private var showGalleryView = false
    @State private var showingIngredientScanner = false
    @State private var showingWebRecipeSearch = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SMColor.surface
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: SMSpacing.xl) {
                    searchBar
                    mealTypeFilterPills
                    difficultyFilterPills

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
        .onAppear {
            aiCoordinator.updateContext(
                AIPageContext(
                    pageType: "recipes",
                    pageLabel: "Your recipes",
                    briefSummary: "Browsing \(appState.recipes.count) saved recipes."
                )
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showGalleryView.toggle()
                    }
                } label: {
                    Image(systemName: showGalleryView ? "square.grid.2x2.fill" : "list.bullet")
                        .foregroundStyle(SMColor.primary)
                }
            }
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
                    Divider()
                    Button {
                        showingWebRecipeSearch = true
                    } label: {
                        Label("Find recipe online", systemImage: "magnifyingglass.circle")
                    }
                    Button {
                        showingIngredientScanner = true
                    } label: {
                        Label("Identify ingredient", systemImage: "viewfinder.circle")
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
        .sheet(isPresented: $showingIngredientScanner) {
            IngredientScannerView { searchTerm in
                searchText = searchTerm
                isSearchFocused = false
            }
        }
        .sheet(isPresented: $showingWebRecipeSearch) {
            RecipeWebSearchSheet { draft in
                editorContext = RecipeEditorSheetContext(
                    title: "Imported from web",
                    draft: draft
                )
            }
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
            if let prefill = appState.recipesPrefilledSearch, !prefill.isEmpty {
                searchText = prefill
                appState.recipesPrefilledSearch = nil
            }
        }
        .onChange(of: appState.recipesPrefilledSearch) { _, newValue in
            if let prefill = newValue, !prefill.isEmpty {
                searchText = prefill
                appState.recipesPrefilledSearch = nil
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

    private var difficultyFilterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SMSpacing.sm) {
                ForEach(DifficultyFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedDifficulty = filter
                        }
                    } label: {
                        Text(filter.label)
                            .font(SMFont.caption)
                            .foregroundStyle(selectedDifficulty == filter ? SMColor.primary : SMColor.textSecondary)
                            .padding(.horizontal, SMSpacing.md)
                            .padding(.vertical, SMSpacing.sm)
                            .background(SMColor.surfaceCard)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(selectedDifficulty == filter ? SMColor.primary : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SMSpacing.lg)
        }
    }

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
            } else if showGalleryView {
                recipeGalleryGrid(recipes: results)
            } else {
                recipeListStack(recipes: results)
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

            // 5. All Recipes — list or gallery depending on toggle
            if !allRecipes.isEmpty {
                VStack(spacing: SMSpacing.sm) {
                    sectionHeader("All Recipes")

                    if showGalleryView {
                        recipeGalleryGrid(recipes: allRecipes)
                    } else {
                        recipeListStack(recipes: allRecipes)
                    }
                }
            }

            // Empty state when there are no recipes at all
            if allRecipes.isEmpty {
                emptyState
            }
        }
    }

    // MARK: - List / Gallery Helpers

    private static let galleryColumns = [
        GridItem(.flexible(), spacing: SMSpacing.md),
        GridItem(.flexible(), spacing: SMSpacing.md),
    ]

    private func recipeListStack(recipes: [RecipeSummary]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                NavigationLink {
                    RecipeDetailView(recipeID: recipe.recipeId)
                } label: {
                    RecipeListRow(recipe: recipe, gradientIndex: index)
                }
                .buttonStyle(.plain)

                if index < recipes.count - 1 {
                    Divider()
                        .foregroundStyle(SMColor.divider)
                }
            }
        }
        .padding(.horizontal, SMSpacing.lg)
    }

    private func recipeGalleryGrid(recipes: [RecipeSummary]) -> some View {
        LazyVGrid(columns: Self.galleryColumns, spacing: SMSpacing.md) {
            ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                NavigationLink {
                    RecipeDetailView(recipeID: recipe.recipeId)
                } label: {
                    RecipeCard(recipe: recipe, gradientIndex: index)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SMSpacing.lg)
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
        VStack(spacing: SMSpacing.xl) {
            Image(systemName: "book.pages")
                .font(.system(size: 56))
                .foregroundStyle(SMColor.primary.opacity(0.7))

            VStack(spacing: SMSpacing.sm) {
                Text("Your Recipe Collection")
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)

                Text("Import recipes from your favorite websites, or let AI create new ones.")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: SMSpacing.md) {
                Button {
                    importLaunchMode = .url
                } label: {
                    Label("Import a Recipe", systemImage: "link")
                        .font(SMFont.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SMSpacing.lg)
                        .foregroundStyle(.white)
                        .background(SMColor.primary)
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    showingAISuggestionSheet = true
                } label: {
                    Label("Ask AI", systemImage: "sparkles")
                        .font(SMFont.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SMSpacing.lg)
                        .foregroundStyle(SMColor.primary)
                        .background(SMColor.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                                .stroke(SMColor.primary.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, SMSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SMSpacing.xxl * 2)
        .padding(.horizontal, SMSpacing.lg)
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
                DayKey.isToday($0.mealDate) && $0.slot.lowercased() == "dinner"
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
            .filter { matchesDifficulty($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredSearchResults: [RecipeSummary] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSearch.isEmpty else { return [] }

        return appState.recipes
            .filter { !$0.archived }
            .filter { matchesMealType($0) }
            .filter { matchesDifficulty($0) }
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

    private func matchesDifficulty(_ recipe: RecipeSummary) -> Bool {
        switch selectedDifficulty {
        case .any:
            return true
        case .easy:
            guard let s = recipe.difficultyScore else { return false }
            return s <= 2
        case .medium:
            return recipe.difficultyScore == 3
        case .hard:
            guard let s = recipe.difficultyScore else { return false }
            return s >= 4
        case .kidFriendly:
            return recipe.kidFriendly
        }
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

enum DifficultyFilter: String, CaseIterable {
    case any
    case easy
    case medium
    case hard
    case kidFriendly

    var label: String {
        switch self {
        case .any: return "Any difficulty"
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        case .kidFriendly: return "Kid-friendly"
        }
    }
}
