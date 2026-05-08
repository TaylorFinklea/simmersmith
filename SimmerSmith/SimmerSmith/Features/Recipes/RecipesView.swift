import SwiftUI
import SimmerSmithKit

struct RecipesView: View {
    @Environment(AppState.self) private var appState
    @Environment(AIAssistantCoordinator.self) private var aiCoordinator

    @State private var searchText = ""
    @State private var selectedMealType: String = ""
    @State private var selectedDifficulty: DifficultyFilter = .any
    /// Build 57 — quick meal filter. Predicate is
    /// `recipe.tags.contains("quick") || prep+cook ≤ 30` (with a
    /// guard so recipes with no time set don't false-positive).
    /// AI drafts auto-tag themselves "quick" when they hit the
    /// threshold; users can also tag manually.
    @State private var quickOnly: Bool = false
    /// M29 build 54 — slop-cleanup filter. When active, swaps
    /// editorial sections for a flat filtered list so the user can
    /// audit AI drafts + unused recipes at a glance.
    @State private var selectedCleanup: RecipeCleanupFilter = .none
    /// M29 build 55 — multi-select cleanup mode. When `true`, recipe
    /// rows show a checkbox + tap-to-toggle; the bottom action bar
    /// exposes bulk Delete. Off by default; entered via the toolbar
    /// "Select" item.
    @State private var isSelecting = false
    @State private var selectedRecipeIDs: Set<String> = []
    @State private var pendingBulkDelete = false
    @State private var isBulkDeleting = false
    /// M29 build 55 — funnel for the web-search review-first refactor.
    @State private var pendingReviewDraft: PendingReviewDraft? = nil

    private struct PendingReviewDraft: Identifiable {
        let id = UUID()
        let draft: RecipeDraft
        let contextHint: String
    }
    @State private var importLaunchMode: RecipeImportLaunchMode?
    @State private var editorContext: RecipeEditorSheetContext?
    @State private var isGeneratingSuggestion = false
    @State private var suggestionErrorMessage: String?
    @State private var showingAISuggestionSheet = false
    @State private var showGalleryView = false
    @State private var showingIngredientScanner = false
    @State private var showingWebRecipeSearch = false
    @FocusState private var isSearchFocused: Bool
    /// Build 63 — Fusion Forge IA. Filters that previously took up
    /// 4 inline rows (difficulty, quick, cleanup) collapse into a
    /// single sheet. Search uses system `.searchable` so it sits
    /// in the Liquid Glass nav bar instead of a custom rounded
    /// search bar inside the scroll.
    @State private var showingFilterSheet = false
    /// Build 72 — search now lives behind a magnifying-glass icon in
    /// the top bar (or the configurable FAB if the user picks Search
    /// as primary). Toggling this animates a paper-styled TextField
    /// in below the hero.
    @State private var showSearchField = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: SMSpacing.xl) {
                    FuHero(
                        eyebrow: "\(appState.recipes.count) forged",
                        title: "the ",
                        emberAccent: "forge",
                        trailing: nil
                    )
                    .padding(.horizontal, -SMSpacing.lg)

                    // Build 72 — manual search field, only present
                    // when toggled. Replaces the always-visible
                    // .searchable drawer.
                    if showSearchField {
                        forgeSearchField
                    }

                    // Build 63 — meal type stays as the visible chip
                    // row (most-used filter). Other filters collapse
                    // behind the Filters toolbar button.
                    mealTypeFilterPills

                    if filterBadgeCount > 0 {
                        activeFiltersSummary
                    }

                    if isGeneratingSuggestion {
                        aiGeneratingBanner
                    }

                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchResults
                    } else if selectedCleanup != .none {
                        cleanupResults
                    } else if showGalleryView {
                        // Build 66 — Gallery is now a true alternate
                        // layout: flat 2-up paper-tile grid of all
                        // recipes, no editorial sections. List view
                        // keeps the editorial structure (Tonight, This
                        // Week, Favorites, Recently Added, All).
                        galleryAllRecipes
                    } else {
                        editorialSections
                    }
                }
                .padding(.horizontal, SMSpacing.lg)
                .padding(.bottom, isSelecting ? 96 : 24)
            }
            .paperBackground()

            // Build 70 — configurable FAB. Default = ➕ Add (rich menu
            // for new recipe / AI suggestion / imports / select).
            // User can swap to Sparkle / Filter / Gallery in
            // Settings → Top bar → Forge.
            if !isSelecting {
                TabPrimaryFAB(page: .forge, contextHint: "from Forge", actions: [
                    .add: {
                        editorContext = RecipeEditorSheetContext(
                            title: "New Recipe",
                            draft: RecipeDraft(name: "", mealType: "dinner")
                        )
                    },
                    .filter: { showingFilterSheet = true },
                    .gallery: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showGalleryView.toggle()
                        }
                    },
                    .search: { activateSearch() }
                ])
            }

            if isSelecting {
                bulkActionBar
            }
        }
        .navigationTitle("Forge")
        .navigationBarTitleDisplayMode(.inline)
        // Build 73 — paper-toned Smith's Notebook toolbar.
        .smithToolbar()
        .sheet(isPresented: $showingFilterSheet) {
            RecipeFilterSheet(
                difficulty: $selectedDifficulty,
                quickOnly: $quickOnly,
                cleanup: $selectedCleanup
            )
        }
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
            // Selection-mode toolbar takes over the right side so the
            // user has unambiguous Cancel + count + (in the bottom bar)
            // a clear delete affordance.
            if isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { exitSelectionMode() }
                        .foregroundStyle(SMColor.primary)
                }
                ToolbarItem(placement: .principal) {
                    Text("\(selectedRecipeIDs.count) selected")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textPrimary)
                }
            } else {
                // Build 72 — Search lives behind a magnifying-glass
                // icon in the top bar. Tapping toggles the inline
                // search field (and focuses it).
                if forgePrimary != .search {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            activateSearch()
                        } label: {
                            Image(systemName: showSearchField ? "magnifyingglass.circle.fill" : "magnifyingglass")
                                .foregroundStyle(SMColor.ember)
                        }
                        .accessibilityLabel(showSearchField ? "Hide search" : "Search recipes")
                    }
                }
                // Build 63 — Filters button replaces the inline filter
                // rows. Build 71 — hide whichever item matches the
                // user's selected FAB action so the same action never
                // shows in both places.
                if forgePrimary != .filter {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle\(filterBadgeCount > 0 ? ".fill" : "")")
                                    .foregroundStyle(SMColor.ember)
                                if filterBadgeCount > 0 {
                                    Text("\(filterBadgeCount)")
                                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                                        .foregroundStyle(SMColor.paper)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(SMColor.ember, in: Capsule())
                                        .offset(x: 8, y: -8)
                                }
                            }
                        }
                        .accessibilityLabel(filterBadgeCount > 0 ? "Filters · \(filterBadgeCount) active" : "Filters")
                    }
                }
                if forgePrimary != .gallery {
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
                }
                if forgePrimary != .add {
                    ToolbarItem(placement: .topBarTrailing) {
                        forgeAddMenu
                    }
                }
                if forgePrimary != .sparkle {
                    ToolbarItem(placement: .topBarTrailing) {
                        TopBarSparkleButton(contextHint: "from Forge")
                    }
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
            // M29 build 55 — web-search results land in the review
            // sheet so the user can refine ("smaller portion for two")
            // or hand-edit before anything saves to the library.
            RecipeWebSearchSheet { draft in
                pendingReviewDraft = PendingReviewDraft(
                    draft: draft,
                    contextHint: "a recipe found via web search"
                )
            }
        }
        .sheet(item: $pendingReviewDraft) { pending in
            RecipeDraftReviewSheet(
                initialDraft: pending.draft,
                refineContextHint: pending.contextHint,
                onSave: { _ in /* recipe is already in `appState.recipes` */ }
            )
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

    // MARK: - Top-bar add menu

    /// Build 71 — read once per render so the conditional
    /// toolbar items above stay consistent with the FAB.
    private var forgePrimary: TopBarPrimaryAction {
        _ = appState.topBarConfigRevision
        return appState.topBarPrimary(for: .forge)
    }

    /// Build 72 — paper-toned manual search field. Replaces the
    /// system `.searchable` drawer so search can be hidden behind
    /// a magnifying-glass icon and selectable as the FAB primary.
    private var forgeSearchField: some View {
        HStack(spacing: SMSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SMColor.ember)
            TextField("Search recipes, tags, memories", text: $searchText)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .textFieldStyle(.plain)
                .foregroundStyle(SMColor.textPrimary)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SMColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Button("Done") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showSearchField = false
                    searchText = ""
                }
                isSearchFocused = false
            }
            .font(SMFont.caption.weight(.semibold))
            .foregroundStyle(SMColor.ember)
        }
        .padding(.horizontal, SMSpacing.md)
        .padding(.vertical, SMSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: SMRadius.md)
                .fill(SMColor.paperAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: SMRadius.md)
                        .stroke(SMColor.rule, lineWidth: 0.5)
                )
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func activateSearch() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showSearchField = true
        }
        // Slight delay so the field is mounted before we focus it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isSearchFocused = true
        }
    }

    private var forgeAddMenu: some View {
        Menu {
            Button {
                editorContext = RecipeEditorSheetContext(
                    title: "New Recipe",
                    draft: RecipeDraft(name: "", mealType: "dinner")
                )
            } label: {
                Label("New recipe", systemImage: "square.and.pencil")
            }
            // M29 build 55 — moved from the (removed) AI FAB.
            Button {
                showingAISuggestionSheet = true
            } label: {
                Label("AI suggestion", systemImage: "sparkles")
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
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isSelecting = true
                }
            } label: {
                Label("Select recipes", systemImage: "checkmark.circle")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(SMColor.ember)
        }
        .accessibilityLabel("Add recipe")
    }

    // MARK: - Search Bar

    // MARK: - Meal Type Filter Pills

    private static let mealTypeFilters: [(label: String, value: String)] = [
        ("All", ""),
        ("Breakfast", "breakfast"),
        ("Lunch", "lunch"),
        ("Dinner", "dinner"),
        ("Snack", "snack"),
    ]

    private var bulkActionBar: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: SMSpacing.md) {
                Button(role: .destructive) {
                    pendingBulkDelete = true
                } label: {
                    HStack(spacing: SMSpacing.sm) {
                        if isBulkDeleting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text(isBulkDeleting ? "Deleting…" : "Delete \(selectedRecipeIDs.count)")
                            .font(SMFont.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.md)
                    .background(SMColor.destructive)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md))
                }
                .buttonStyle(.plain)
                .disabled(selectedRecipeIDs.isEmpty || isBulkDeleting)
            }
            .padding(.horizontal, SMSpacing.lg)
            .padding(.vertical, SMSpacing.md)
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea(edges: .bottom)
        .confirmationDialog(
            "Delete \(selectedRecipeIDs.count) recipe\(selectedRecipeIDs.count == 1 ? "" : "s")?",
            isPresented: $pendingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedRecipeIDs.count)", role: .destructive) {
                Task { await performBulkDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected recipes. Any week meals or sides linked to them will keep their dish name but lose the recipe link.")
        }
    }

    private func exitSelectionMode() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isSelecting = false
            selectedRecipeIDs.removeAll()
        }
    }

    private func toggleSelection(_ recipe: RecipeSummary) {
        if selectedRecipeIDs.contains(recipe.recipeId) {
            selectedRecipeIDs.remove(recipe.recipeId)
        } else {
            selectedRecipeIDs.insert(recipe.recipeId)
        }
    }

    private func performBulkDelete() async {
        guard !selectedRecipeIDs.isEmpty else { return }
        isBulkDeleting = true
        defer { isBulkDeleting = false }
        let snapshot = appState.recipes.filter { selectedRecipeIDs.contains($0.recipeId) }
        var failed: [String] = []
        for recipe in snapshot {
            do {
                try await appState.deleteRecipe(recipe)
            } catch {
                failed.append(recipe.name)
            }
        }
        if failed.isEmpty {
            exitSelectionMode()
        } else {
            // Surface partial failure but keep selection so the user
            // can retry the failed ones. The successful ones are
            // gone from `appState.recipes` already.
            appState.lastErrorMessage = "Couldn't delete: \(failed.joined(separator: ", "))"
            selectedRecipeIDs = Set(failed.compactMap { name in
                appState.recipes.first(where: { $0.name == name })?.recipeId
            })
        }
    }

    /// M29 build 54 — flat filtered list for cleanup mode. Sorted
    /// least-recently-used first so abandoned AI drafts surface
    /// before favorites.
    private var cleanupResults: some View {
        let results = filteredCleanup
        return Group {
            if results.isEmpty {
                ContentUnavailableView(
                    "Nothing matches that filter",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Tap the filter pill again to clear it.")
                )
                .padding(.horizontal, SMSpacing.lg)
            } else if showGalleryView {
                recipeGalleryGrid(recipes: results)
            } else {
                recipeListStack(recipes: results)
            }
        }
    }

    private var filteredCleanup: [RecipeSummary] {
        let base = appState.recipes
            .filter { !$0.archived }
            .filter { matchesMealType($0) }
            .filter { matchesDifficulty($0) }
            .filter { matchesQuick($0) }

        let filtered: [RecipeSummary]
        switch selectedCleanup {
        case .none:
            filtered = base
        case .aiGenerated:
            filtered = base.filter { $0.source.hasPrefix("ai") }
        case .neverUsed:
            filtered = base.filter { $0.lastUsed == nil }
        case .unusedRecently:
            filtered = base.filter { recipe in
                guard let days = recipe.daysSinceLastUsed else { return true }
                return days >= 30
            }
        }

        // Least-recently-used first puts abandoned drafts at the top
        // of the cleanup list (the whole point — find them quickly).
        return filtered.sorted { lhs, rhs in
            let l = lhs.daysSinceLastUsed ?? Int.max
            let r = rhs.daysSinceLastUsed ?? Int.max
            if l != r { return l > r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var mealTypeFilterPills: some View {
        // Build 63 — Fusion outlined Caveat chips with slight
        // rotations. Horizontal scroll keeps long lists readable on
        // smaller devices.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SMSpacing.sm) {
                ForEach(Array(Self.mealTypeFilters.enumerated()), id: \.element.value) { idx, filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedMealType = filter.value
                        }
                    } label: {
                        FuOutlinedPill(
                            label: filter.label,
                            color: SMColor.ember,
                            filled: selectedMealType == filter.value,
                            rotation: idx.isMultiple(of: 2) ? -0.6 : 0.6
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SMSpacing.lg)
            .padding(.vertical, 4)
        }
    }

    /// Build 63 — counts how many of the advanced filters
    /// (difficulty / quick / cleanup) are non-default. Drives the
    /// filter-button badge.
    private var filterBadgeCount: Int {
        var n = 0
        if selectedDifficulty != .any { n += 1 }
        if quickOnly { n += 1 }
        if selectedCleanup != .none { n += 1 }
        return n
    }

    /// Build 63 — small Caveat ember row showing the active advanced
    /// filters when at least one is on. Tap to clear them all.
    @ViewBuilder
    private var activeFiltersSummary: some View {
        let parts: [String] = [
            selectedDifficulty == .any ? nil : selectedDifficulty.label.lowercased(),
            quickOnly ? "quick (≤30 min)" : nil,
            selectedCleanup == .none ? nil : selectedCleanup.label.lowercased()
        ].compactMap { $0 }

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedDifficulty = .any
                quickOnly = false
                selectedCleanup = .none
            }
        } label: {
            HStack(spacing: SMSpacing.sm) {
                Text(parts.joined(separator: " · "))
                    .font(SMFont.handwritten(14))
                    .foregroundStyle(SMColor.ember)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SMColor.ember)
                Spacer()
            }
            .padding(.horizontal, SMSpacing.lg)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear \(parts.count) active filter\(parts.count == 1 ? "" : "s")")
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
                                HandRule(color: SMColor.rule, height: 4, lineWidth: 0.7)
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
        // Build 65 — Fusion list: HandRule between rows (no solid
        // Divider) so the list reads as a notebook page rather than
        // a system table.
        LazyVStack(spacing: 0) {
            ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                if isSelecting {
                    Button {
                        toggleSelection(recipe)
                    } label: {
                        HStack(spacing: SMSpacing.md) {
                            Image(systemName: selectedRecipeIDs.contains(recipe.recipeId)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedRecipeIDs.contains(recipe.recipeId)
                                                 ? SMColor.ember
                                                 : SMColor.inkFaint)
                            RecipeListRow(recipe: recipe, gradientIndex: index)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        RecipeDetailView(recipeID: recipe.recipeId)
                    } label: {
                        RecipeListRow(recipe: recipe, gradientIndex: index)
                    }
                    .buttonStyle(.plain)
                }

                if index < recipes.count - 1 {
                    HandRule(color: SMColor.rule, height: 4, lineWidth: 0.7)
                }
            }
        }
        .padding(.horizontal, SMSpacing.lg)
    }

    /// Build 66 — Gallery is the alternate top-level layout (toggled
    /// from the toolbar). Shows all non-archived recipes in a flat
    /// 2-up paper-tile grid, no editorial sections — that's the
    /// whole point of toggling.
    @ViewBuilder
    private var galleryAllRecipes: some View {
        if allRecipes.isEmpty {
            emptyState
        } else {
            recipeGalleryGrid(recipes: allRecipes)
        }
    }

    private func recipeGalleryGrid(recipes: [RecipeSummary]) -> some View {
        LazyVGrid(columns: Self.galleryColumns, spacing: SMSpacing.md) {
            ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                if isSelecting {
                    Button {
                        toggleSelection(recipe)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            RecipeCard(recipe: recipe, gradientIndex: index)
                            Image(systemName: selectedRecipeIDs.contains(recipe.recipeId)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedRecipeIDs.contains(recipe.recipeId)
                                                 ? SMColor.primary
                                                 : SMColor.textTertiary)
                                .padding(SMSpacing.sm)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(SMSpacing.xs)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        RecipeDetailView(recipeID: recipe.recipeId)
                    } label: {
                        RecipeCard(recipe: recipe, gradientIndex: index)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, SMSpacing.lg)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        // Build 65 — Fusion notebook section header. Caveat
        // handwritten + ember underline matches the Week tab's
        // "the week" pattern so the editorial sections read as
        // chapters in the same notebook.
        HStack(spacing: SMSpacing.sm) {
            Text(title.lowercased())
                .font(SMFont.handwritten(20, bold: true))
                .foregroundStyle(SMColor.ink)
            HandUnderline(color: SMColor.ember, width: 36)
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
            .filter { matchesQuick($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredSearchResults: [RecipeSummary] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSearch.isEmpty else { return [] }

        return appState.recipes
            .filter { !$0.archived }
            .filter { matchesMealType($0) }
            .filter { matchesDifficulty($0) }
            .filter { matchesQuick($0) }
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

    /// Build 57 — Quick filter predicate. Manual tag wins so a user
    /// can mark a 35-minute recipe "quick" if they trust their pace;
    /// auto path is `prep+cook ≤ 30` with a guard for unset times so
    /// recipes with no `prepMinutes`/`cookMinutes` don't slip in.
    private func matchesQuick(_ recipe: RecipeSummary) -> Bool {
        if !quickOnly { return true }
        if recipe.tags.contains("quick") { return true }
        let total = (recipe.prepMinutes ?? 0) + (recipe.cookMinutes ?? 0)
        return total > 0 && total <= 30
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

/// M29 build 54 — surfaces for finding AI slop + abandoned recipes.
enum RecipeCleanupFilter: String, CaseIterable {
    case none
    case aiGenerated
    case neverUsed
    case unusedRecently

    var label: String {
        switch self {
        case .none: return "All recipes"
        case .aiGenerated: return "AI-generated"
        case .neverUsed: return "Never used"
        case .unusedRecently: return "Unused 30+ days"
        }
    }

    var iconName: String {
        switch self {
        case .none: return "tray.full"
        case .aiGenerated: return "sparkles"
        case .neverUsed: return "tray"
        case .unusedRecently: return "clock.badge.exclamationmark"
        }
    }
}
