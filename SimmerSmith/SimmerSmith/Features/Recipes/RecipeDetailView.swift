import SwiftUI
import SimmerSmithKit

struct RecipeDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(AIAssistantCoordinator.self) private var aiCoordinator
    @Environment(\.dismiss) private var dismiss

    let recipeID: String

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editorContext: RecipeEditorSheetContext?
    @State private var assignmentContext: RecipeAssignmentSheetContext?
    @State private var companionContext: RecipeCompanionSheetContext?
    @State private var nutritionMatchContext: RecipeNutritionMatchContext?
    @State private var substitutionContext: SubstitutionSheetContext?
    // Transient toast shown after marking an ingredient avoid/allergy —
    // clears itself after ~2s via a Task.sleep.
    @State private var preferenceToast: String?
    @State private var pendingDelete = false
    @State private var selectedScale: RecipeScaleOption = .single
    @State private var isGeneratingVariation = false
    @State private var isGeneratingCompanions = false
    @State private var showingSteps: Bool = false

    var body: some View {
        Group {
            if let recipe {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection(recipe)
                        contentSections(recipe)
                    }
                }
                .background(SMColor.surface)
                .scrollContentBackground(.hidden)
            } else if isLoading {
                ZStack {
                    SMColor.surface.ignoresSafeArea()
                    ProgressView("Loading recipe...")
                        .tint(SMColor.primary)
                        .foregroundStyle(SMColor.textSecondary)
                }
            } else {
                ZStack {
                    SMColor.surface.ignoresSafeArea()
                    VStack(spacing: SMSpacing.lg) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 48))
                            .foregroundStyle(SMColor.textTertiary)
                        Text("Recipe Unavailable")
                            .font(SMFont.headline)
                            .foregroundStyle(SMColor.textPrimary)
                        Text(errorMessage ?? "The recipe could not be loaded.")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(SMSpacing.xl)
                }
            }
        }
        .navigationTitle(recipe?.name ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(SMColor.surface, for: .navigationBar)
        .onAppear { publishContext() }
        .onChange(of: recipe?.recipeId) { _, _ in publishContext() }
        .overlay(alignment: .top) {
            if let toast = preferenceToast {
                Text(toast)
                    .font(SMFont.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SMSpacing.md)
                    .padding(.vertical, SMSpacing.sm)
                    .background(SMColor.primary.opacity(0.92), in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, SMSpacing.lg)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: preferenceToast)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let recipe {
                    HStack(spacing: SMSpacing.lg) {
                        Button {
                            Task { await toggleFavorite(recipe) }
                        } label: {
                            Image(systemName: recipe.favorite ? "heart.fill" : "heart")
                                .foregroundStyle(recipe.favorite ? SMColor.favoritePink : SMColor.textSecondary)
                        }

                        Menu {
                            Button {
                                editorContext = RecipeEditorSheetContext(title: "Edit Recipe", draft: recipe.editingDraft())
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button {
                                editorContext = RecipeEditorSheetContext(title: "New Variation", draft: recipe.variationDraft())
                            } label: {
                                Label("Create Variation", systemImage: "square.on.square")
                            }
                            Menu("AI Variation Draft") {
                                ForEach(RecipeVariationGoal.allCases) { goal in
                                    Button(goal.title) {
                                        Task { await generateVariation(recipe, goal: goal) }
                                    }
                                    .disabled(isGeneratingVariation)
                                }
                            }
                            Button {
                                Task { await generateCompanions(recipe) }
                            } label: {
                                Label("AI Companion Suggestions", systemImage: "sparkles")
                            }
                            .disabled(isGeneratingCompanions)
                            Button {
                                Task {
                                    do {
                                        try await appState.beginAssistantLaunch(
                                            initialText: "Help me with this recipe. Suggest improvements, substitutions, or troubleshooting advice.",
                                            title: recipe.name,
                                            attachedRecipeID: recipe.recipeId,
                                            intent: "cooking_help"
                                        )
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Label("Ask Assistant", systemImage: "bubble.left.and.text.bubble.right")
                            }
                            Button {
                                assignmentContext = RecipeAssignmentSheetContext(recipes: [recipe])
                            } label: {
                                Label("Add to Week", systemImage: "calendar.badge.plus")
                            }
                            ShareLink(
                                item: formatRecipeForSharing(recipe),
                                subject: Text(recipe.name),
                                message: Text("Check out this recipe!")
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Divider()
                            if recipe.archived {
                                Button {
                                    Task { await restore(recipe) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                            } else {
                                Button {
                                    Task { await archive(recipe) }
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                            Button(role: .destructive) {
                                pendingDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                }
            }
        }
        .task(id: recipeID) {
            await loadRecipe()
        }
        .sheet(item: $editorContext) { context in
            RecipeEditorView(title: context.title, initialDraft: context.draft) { _ in
                Task { await loadRecipe(forceRefresh: true) }
            }
        }
        .sheet(item: $assignmentContext) { context in
            RecipeWeekAssignmentView(recipes: context.recipes)
        }
        .sheet(item: $companionContext) { context in
            RecipeCompanionOptionsView(context: context) { selected in
                companionContext = nil
                editorContext = RecipeEditorSheetContext(
                    title: "\(selected.label) Draft",
                    draft: selected.draft
                )
            }
        }
        .sheet(item: $nutritionMatchContext) { context in
            RecipeNutritionMatchView(context: context) {
                Task { await loadRecipe(forceRefresh: true) }
            }
        }
        .sheet(item: $substitutionContext) { context in
            SubstitutionSheetView(
                recipe: context.recipe,
                ingredient: context.ingredient,
                onApplied: {
                    Task { await loadRecipe(forceRefresh: true) }
                },
                onVariationCreated: { _ in
                    // Refresh the library so the new variation shows up.
                    // The user stays on the original recipe — the
                    // variation is reachable from the Recipes list.
                    Task { await appState.refreshRecipes() }
                }
            )
        }
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let recipe {
                    Task { await delete(recipe) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recipe from the library. Existing week meals keep their copied names and ingredients.")
        }
    }

    // MARK: - Header Section

    private func headerSection(_ recipe: RecipeSummary) -> some View {
        ZStack(alignment: .bottomLeading) {
            // TODO: When RecipeSummary gains an imageURL field, replace this gradient
            // placeholder with AsyncImage:
            //   if let imageURL = recipe.imageURL, let url = URL(string: imageURL) {
            //       AsyncImage(url: url) { image in
            //           image.resizable().aspectRatio(contentMode: .fill)
            //       } placeholder: { gradient }
            //       .frame(height: 200).clipped()
            //   }
            RoundedRectangle(cornerRadius: 0)
                .fill(recipeHeaderGradient(for: recipe))
                .frame(height: 200)

            // Title and metadata overlay
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                if recipe.archived {
                    Text("ARCHIVED")
                        .font(SMFont.label)
                        .foregroundStyle(SMColor.textTertiary)
                        .padding(.horizontal, SMSpacing.sm)
                        .padding(.vertical, SMSpacing.xs)
                        .background(SMColor.surface.opacity(0.6))
                        .clipShape(Capsule())
                }

                Text(recipe.name)
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(3)

                if !recipe.subtitleFragments.isEmpty {
                    Text(recipe.subtitleFragments.joined(separator: " \u{2022} "))
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
            .padding(SMSpacing.xl)
        }
    }

    // MARK: - Content Sections

    private func contentSections(_ recipe: RecipeSummary) -> some View {
        VStack(spacing: SMSpacing.lg) {
            // AI progress indicators
            if isGeneratingVariation {
                aiProgressCard(text: "Generating AI variation draft...")
            }

            if isGeneratingCompanions {
                aiProgressCard(text: "Generating companion suggestions...")
            }

            // Metadata pills (wrapping)
            metadataPills(recipe)

            // Tags
            if !recipe.tags.isEmpty {
                tagSection(recipe)
            }

            // Scale picker
            scaleSection

            // Calories (full nutrition section)
            if let nutritionSummary = recipe.nutritionSummary {
                nutritionSection(recipe, nutritionSummary: nutritionSummary)
            }

            // Variations
            if !variantRecipes(for: recipe).isEmpty {
                variationsSection(recipe)
            }

            // Ingredients / Steps toggle
            if !recipe.ingredients.isEmpty || !recipe.steps.isEmpty || !recipe.instructionsSummary.isEmpty {
                ingredientsStepsPicker

                if showingSteps {
                    if !recipe.steps.isEmpty {
                        stepsSection(recipe)
                    } else if !recipe.instructionsSummary.isEmpty {
                        instructionsSummarySection(recipe)
                    } else {
                        SMCard {
                            Text("No steps have been added yet.")
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                } else {
                    if !recipe.ingredients.isEmpty {
                        ingredientsSection(recipe)
                    } else {
                        SMCard {
                            Text("No ingredients have been added yet.")
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                }
            }

            // Notes
            if !recipe.notes.isEmpty {
                notesSection(title: "Notes", text: recipe.notes, icon: "note.text")
            }

            // Memories
            if !recipe.memories.isEmpty {
                notesSection(title: "Memories", text: recipe.memories, icon: "brain")
            }

            // Source
            if !recipe.sourceLabel.isEmpty || !recipe.sourceUrl.isEmpty || recipe.sourceRecipeCount > 0 {
                sourceSection(recipe)
            }

            // Error
            if let errorMessage {
                SMCard {
                    Text(errorMessage)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.destructive)
                }
            }
        }
        .padding(.horizontal, SMSpacing.lg)
        .padding(.top, SMSpacing.lg)
        .padding(.bottom, SMSpacing.xxl)
    }

    // MARK: - Metadata Pills

    private func metadataPills(_ recipe: RecipeSummary) -> some View {
        WrappingHStack(spacing: SMSpacing.sm) {
            if let servings = recipe.servings {
                metadataPill(icon: "person.2", text: "\(servings.formatted()) servings")
            }
            if let prepMinutes = recipe.prepMinutes {
                metadataPill(icon: "timer", text: "\(prepMinutes)m prep")
            }
            if let cookMinutes = recipe.cookMinutes {
                metadataPill(icon: "flame", text: "\(cookMinutes)m cook")
            }
            if let calorieChipText = calorieChipText(for: recipe) {
                metadataPill(icon: "flame.circle", text: calorieChipText)
            }

            metadataPill(icon: "clock.arrow.circlepath", text: recipe.usageSummary)

            if !recipe.overrideFields.isEmpty {
                metadataPill(icon: "slider.horizontal.3", text: recipe.overrideFields.joined(separator: ", "))
            }
        }
    }

    private func calorieChipText(for recipe: RecipeSummary) -> String? {
        guard let nutrition = recipe.nutritionSummary else { return nil }
        let hasUnmatched = nutrition.unmatchedIngredientCount > 0
        if let cps = nutrition.caloriesPerServing {
            let value = Int(cps.rounded())
            return hasUnmatched ? "~\(value) cal (estimate)" : "\(value) cal"
        }
        if let total = nutrition.totalCalories {
            let value = Int(total.rounded())
            return hasUnmatched ? "~\(value) cal (estimate)" : "\(value) cal"
        }
        return nil
    }

    private func metadataPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(SMFont.caption)
            .foregroundStyle(SMColor.textSecondary)
            .padding(.horizontal, SMSpacing.md)
            .padding(.vertical, SMSpacing.sm)
            .background(SMColor.surfaceCard)
            .clipShape(Capsule())
    }

    // MARK: - Ingredients / Steps Picker

    private var ingredientsStepsPicker: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showingSteps = false
                }
            } label: {
                Text("Ingredients")
                    .font(SMFont.label)
                    .foregroundStyle(!showingSteps ? SMColor.primary : SMColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.md)
                    .background(!showingSteps ? SMColor.primary.opacity(0.15) : Color.clear)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showingSteps = true
                }
            } label: {
                Text("Steps")
                    .font(SMFont.label)
                    .foregroundStyle(showingSteps ? SMColor.primary : SMColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.md)
                    .background(showingSteps ? SMColor.primary.opacity(0.15) : Color.clear)
            }
            .buttonStyle(.plain)
        }
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
    }

    // MARK: - Tags

    private func tagSection(_ recipe: RecipeSummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SMSpacing.sm) {
                ForEach(recipe.tags, id: \.self) { tag in
                    Text(tag)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.primary)
                        .padding(.horizontal, SMSpacing.md)
                        .padding(.vertical, SMSpacing.xs)
                        .background(SMColor.primary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Scale

    private var scaleSection: some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Scale")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                HStack(spacing: SMSpacing.sm) {
                    ForEach(RecipeScaleOption.allCases) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedScale = option
                            }
                        } label: {
                            Text(option.title)
                                .font(SMFont.label)
                                .foregroundStyle(selectedScale == option ? .white : SMColor.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SMSpacing.sm)
                                .background(selectedScale == option ? SMColor.primary : SMColor.surface)
                                .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Nutrition

    private func nutritionSection(_ recipe: RecipeSummary, nutritionSummary: NutritionSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                Text("Calories")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                if let caloriesPerServing = nutritionSummary.caloriesPerServing {
                    Text("\(Int(caloriesPerServing.rounded())) calories per serving")
                        .font(SMFont.headline)
                        .foregroundStyle(SMColor.textPrimary)
                } else if let totalCalories = nutritionSummary.totalCalories {
                    Text("\(Int(totalCalories.rounded())) calories total")
                        .font(SMFont.headline)
                        .foregroundStyle(SMColor.textPrimary)
                } else {
                    Text("No calorie estimate yet")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textSecondary)
                }

                HStack(spacing: SMSpacing.md) {
                    Text(nutritionSummary.statusLabel)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                    Text("\(nutritionSummary.matchedIngredientCount) matched")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.success)
                    if nutritionSummary.unmatchedIngredientCount > 0 {
                        Text("\(nutritionSummary.unmatchedIngredientCount) unmatched")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.accent)
                    }
                }

                if !nutritionSummary.unmatchedIngredients.isEmpty {
                    Divider()
                        .background(SMColor.divider)

                    ForEach(nutritionSummary.unmatchedIngredients, id: \.self) { ingredient in
                        Button {
                            let normalizedName = recipe.ingredients.first {
                                $0.ingredientName.localizedCaseInsensitiveCompare(ingredient) == .orderedSame
                            }?.normalizedName
                            nutritionMatchContext = RecipeNutritionMatchContext(
                                ingredientName: ingredient,
                                normalizedName: normalizedName
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ingredient)
                                        .font(SMFont.body)
                                        .foregroundStyle(SMColor.textPrimary)
                                    Text("Match nutrition to improve this estimate")
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SMColor.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Variations

    private func variationsSection(_ recipe: RecipeSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                Text("Variations")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                ForEach(variantRecipes(for: recipe)) { variant in
                    NavigationLink {
                        RecipeDetailView(recipeID: variant.recipeId)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                                Text(variant.name)
                                    .font(SMFont.subheadline)
                                    .foregroundStyle(SMColor.textPrimary)
                                Text(variant.usageSummary)
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Ingredients

    private func ingredientsSection(_ recipe: RecipeSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                Text("Ingredients")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                ForEach(recipe.ingredients.map { $0.scaled(by: selectedScale.rawValue) }) { ingredient in
                    HStack(alignment: .top) {
                        // Quantity + unit left-aligned
                        HStack(spacing: SMSpacing.xs) {
                            if let quantity = ingredient.quantity {
                                Text(quantity.formatted())
                                    .font(SMFont.body)
                                    .foregroundStyle(SMColor.primary)
                            }
                            if !ingredient.unit.isEmpty {
                                Text(ingredient.unit)
                                    .font(SMFont.body)
                                    .foregroundStyle(SMColor.primary)
                            }
                        }
                        .frame(minWidth: 60, alignment: .leading)

                        // Name + prep right
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ingredient.ingredientName)
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textPrimary)

                            if !ingredient.prep.isEmpty {
                                Text(ingredient.prep)
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textTertiary)
                            }
                        }

                        Spacer()

                        // Per-ingredient AI menu: substitute, never plan
                        // with this, or mark as allergy. The bottom two
                        // options need a resolved baseIngredientId so they
                        // can upsert an IngredientPreference row keyed on
                        // the catalog entry.
                        Menu {
                            Button {
                                substitutionContext = SubstitutionSheetContext(
                                    recipe: recipe,
                                    ingredient: ingredient
                                )
                            } label: {
                                Label("Substitute…", systemImage: "arrow.triangle.2.circlepath")
                            }

                            if let baseID = ingredient.baseIngredientId, !baseID.isEmpty {
                                Divider()
                                Button {
                                    Task { await markPreference(ingredient: ingredient, mode: "avoid") }
                                } label: {
                                    Label("Never use this in my plans", systemImage: "nosign")
                                }
                                Button(role: .destructive) {
                                    Task { await markPreference(ingredient: ingredient, mode: "allergy") }
                                } label: {
                                    Label("I'm allergic to this", systemImage: "exclamationmark.triangle")
                                }
                            }
                        } label: {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(SMColor.aiPurple.opacity(0.85))
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("Options for \(ingredient.ingredientName)")
                    }

                    if ingredient.id != recipe.ingredients.last?.id {
                        Divider()
                            .background(SMColor.divider)
                    }
                }
            }
        }
    }

    // MARK: - Steps

    private func stepsSection(_ recipe: RecipeSummary) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.md) {
            Text("Steps")
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)
                .padding(.leading, SMSpacing.xs)

            ForEach(recipe.steps.sorted(by: { $0.sortOrder < $1.sortOrder })) { step in
                SMCard {
                    VStack(alignment: .leading, spacing: SMSpacing.sm) {
                        Text("\(step.sortOrder)")
                            .font(SMFont.headline)
                            .foregroundStyle(SMColor.primary)

                        Text(step.instruction)
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textPrimary)

                        if !step.substeps.isEmpty {
                            ForEach(step.substeps.sorted(by: { $0.sortOrder < $1.sortOrder })) { substep in
                                HStack(alignment: .top, spacing: SMSpacing.sm) {
                                    Text("\(substepMarker(for: substep.sortOrder)).")
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textTertiary)
                                    Text(substep.instruction)
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textSecondary)
                                }
                                .padding(.leading, SMSpacing.md)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Instructions Summary

    private func instructionsSummarySection(_ recipe: RecipeSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Instructions")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                Text(recipe.instructionsSummary)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
            }
        }
    }

    // MARK: - Notes / Memories

    private func notesSection(title: String, text: String, icon: String) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Label(title, systemImage: icon)
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                Text(text)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
            }
        }
    }

    // MARK: - Source

    private func sourceSection(_ recipe: RecipeSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Source")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                if !recipe.sourceLabel.isEmpty {
                    Text(recipe.sourceLabel)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textPrimary)
                }

                if recipe.sourceRecipeCount > 0 {
                    Text("\(recipe.sourceRecipeCount) recipes from this source")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }

                if let url = URL(string: recipe.sourceUrl), !recipe.sourceUrl.isEmpty {
                    Link(destination: url) {
                        Label("Open original recipe", systemImage: "safari")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.primary)
                    }
                }
            }
        }
    }

    // MARK: - AI Progress Card

    private func aiProgressCard(text: String) -> some View {
        HStack(spacing: SMSpacing.md) {
            ProgressView()
                .tint(SMColor.aiPurple)
            Text(text)
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SMSpacing.lg)
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
    }

    // MARK: - Helpers

    private func recipeHeaderGradient(for recipe: RecipeSummary) -> LinearGradient {
        let hash = abs(recipe.recipeId.hashValue)
        return SMColor.recipeGradients[hash % SMColor.recipeGradients.count]
    }

    private var recipe: RecipeSummary? {
        appState.recipes.first { $0.recipeId == recipeID }
    }

    private func ingredientLine(for ingredient: RecipeIngredient) -> String {
        [
            ingredient.quantity.map { $0.formatted() },
            ingredient.unit.isEmpty ? nil : ingredient.unit,
            ingredient.prep.isEmpty ? nil : ingredient.prep,
            ingredient.category.isEmpty ? nil : ingredient.category,
        ]
        .compactMap { $0 }
        .joined(separator: " \u{2022} ")
    }

    private func variantRecipes(for recipe: RecipeSummary) -> [RecipeSummary] {
        let rootID = recipe.baseRecipeId ?? recipe.recipeId
        return appState.recipes
            .filter { $0.baseRecipeId == rootID && $0.recipeId != recipe.recipeId && !$0.archived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func substepMarker(for index: Int) -> String {
        let base = UnicodeScalar(UInt32(96 + max(index, 1))) ?? UnicodeScalar(97)!
        return String(Character(base))
    }

    private func loadRecipe(forceRefresh: Bool = false) async {
        if !forceRefresh, recipe != nil {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            _ = try await appState.fetchRecipe(recipeID: recipeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive(_ recipe: RecipeSummary) async {
        do {
            try await appState.archiveRecipe(recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publishContext() {
        guard let recipe else {
            aiCoordinator.updateContext(
                AIPageContext(pageType: "recipe_detail", pageLabel: "Recipe")
            )
            return
        }
        aiCoordinator.updateContext(
            AIPageContext(
                pageType: "recipe_detail",
                pageLabel: recipe.name,
                recipeId: recipe.recipeId,
                recipeName: recipe.name,
                briefSummary: recipeSummaryText(recipe)
            )
        )
    }

    private func recipeSummaryText(_ recipe: RecipeSummary) -> String {
        var parts: [String] = []
        if !recipe.cuisine.isEmpty { parts.append(recipe.cuisine) }
        if !recipe.mealType.isEmpty { parts.append(recipe.mealType) }
        if let servings = recipe.servings { parts.append("\(Int(servings)) servings") }
        return parts.joined(separator: " · ")
    }

    /// Upsert an IngredientPreference with `choice_mode = avoid` or
    /// `allergy` keyed on the recipe ingredient's baseIngredientId, then
    /// flash a toast. Next time the planner runs, the AI won't propose
    /// meals with this ingredient. Existing recipes in the library are
    /// unaffected — those are data, not plans.
    private func markPreference(ingredient: RecipeIngredient, mode: String) async {
        guard let baseID = ingredient.baseIngredientId, !baseID.isEmpty else { return }
        do {
            _ = try await appState.upsertIngredientPreference(
                baseIngredientID: baseID,
                choiceMode: mode
            )
            let verb = mode == "allergy" ? "Allergy noted" : "Avoiding"
            preferenceToast = "\(verb): \(ingredient.ingredientName)"
            // Auto-dismiss the toast after ~2s. A new mark will overwrite.
            let snapshot = preferenceToast
            try? await Task.sleep(for: .seconds(2))
            if preferenceToast == snapshot {
                preferenceToast = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleFavorite(_ recipe: RecipeSummary) async {
        var draft = recipe.editingDraft()
        draft.favorite = !recipe.favorite
        do {
            _ = try await appState.saveRecipe(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateVariation(_ recipe: RecipeSummary, goal: RecipeVariationGoal) async {
        isGeneratingVariation = true
        defer { isGeneratingVariation = false }

        do {
            let aiDraft = try await appState.generateRecipeVariationDraft(recipeID: recipe.recipeId, goal: goal.title)
            editorContext = RecipeEditorSheetContext(
                title: "\(aiDraft.goal) Draft",
                draft: aiDraft.draft
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateCompanions(_ recipe: RecipeSummary) async {
        isGeneratingCompanions = true
        defer { isGeneratingCompanions = false }

        do {
            let options = try await appState.generateRecipeCompanionDrafts(recipeID: recipe.recipeId)
            companionContext = RecipeCompanionSheetContext(
                title: "\(recipe.name) Companions",
                options: options
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ recipe: RecipeSummary) async {
        do {
            try await appState.restoreRecipe(recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ recipe: RecipeSummary) async {
        do {
            try await appState.deleteRecipe(recipe)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatRecipeForSharing(_ recipe: RecipeSummary) -> String {
        var lines: [String] = []

        lines.append(recipe.name)

        // Metadata line
        var meta: [String] = []
        if let servings = recipe.servings {
            meta.append("Serves \(servings.formatted())")
        }
        if let prep = recipe.prepMinutes, prep > 0 {
            meta.append("Prep: \(prep)m")
        }
        if let cook = recipe.cookMinutes, cook > 0 {
            meta.append("Cook: \(cook)m")
        }
        if !meta.isEmpty {
            lines.append(meta.joined(separator: " | "))
        }

        // Ingredients
        if !recipe.ingredients.isEmpty {
            lines.append("")
            lines.append("Ingredients:")
            for ingredient in recipe.ingredients {
                var parts: [String] = []
                if let quantity = ingredient.quantity {
                    parts.append(quantity.formatted())
                }
                if !ingredient.unit.isEmpty {
                    parts.append(ingredient.unit)
                }
                parts.append(ingredient.ingredientName)
                if !ingredient.prep.isEmpty {
                    parts.append(ingredient.prep)
                }
                lines.append("- \(parts.joined(separator: " "))")
            }
        }

        // Steps
        if !recipe.steps.isEmpty {
            lines.append("")
            lines.append("Steps:")
            for step in recipe.steps.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                lines.append("\(step.sortOrder). \(step.instruction)")
                for substep in step.substeps.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    lines.append("   \(substep.instruction)")
                }
            }
        } else if !recipe.instructionsSummary.isEmpty {
            lines.append("")
            lines.append("Instructions:")
            lines.append(recipe.instructionsSummary)
        }

        // Notes
        if !recipe.notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(recipe.notes)
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Companion Options (dark theme)

private struct RecipeCompanionOptionsView: View {
    let context: RecipeCompanionSheetContext
    let onSelect: (RecipeAIDraftOption) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SMSpacing.lg) {
                    // Rationale card
                    SMCard {
                        VStack(alignment: .leading, spacing: SMSpacing.sm) {
                            Text(context.options.goal)
                                .font(SMFont.label)
                                .foregroundStyle(SMColor.textTertiary)
                            Text(context.options.rationale)
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }

                    // Options
                    ForEach(context.options.options) { option in
                        Button {
                            onSelect(option)
                        } label: {
                            SMCard {
                                VStack(alignment: .leading, spacing: SMSpacing.sm) {
                                    HStack {
                                        Text(option.label)
                                            .font(SMFont.subheadline)
                                            .foregroundStyle(SMColor.textPrimary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                            .foregroundStyle(SMColor.textTertiary)
                                    }
                                    Text(option.draft.name)
                                        .font(SMFont.headline)
                                        .foregroundStyle(SMColor.primary)
                                    Text(option.rationale)
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(SMSpacing.lg)
            }
            .background(SMColor.surface)
            .scrollContentBackground(.hidden)
            .navigationTitle(context.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
    }
}
