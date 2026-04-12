import SwiftUI
import SimmerSmithKit

struct WeekView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedMealForAction: WeekMeal?
    @State private var editingMeal: WeekMeal?
    @State private var navigatingToRecipeID: String?
    @State private var showingActivity = false
    @State private var showingAIPlanner = false
    @State private var showingGrocery = false
    @State private var showingSettings = false
    @State private var aiPrompt = ""
    @State private var isGenerating = false
    @State private var generationError: String?

    // Week navigation
    @State private var displayedWeekStart: Date?
    @State private var availableWeeks: [WeekSummary] = []
    @State private var browsedWeek: WeekSnapshot?

    // Meal quick-add
    @State private var quickAddSlot: (dayName: String, mealDate: Date, slot: String)?

    // Meal rename
    @State private var renamingMeal: WeekMeal?
    @State private var renameText: String = ""

    private var displayedWeek: WeekSnapshot? {
        if displayedWeekStart != nil {
            return browsedWeek ?? appState.currentWeek
        }
        return appState.currentWeek
    }

    private var isViewingCurrentWeek: Bool {
        displayedWeekStart == nil
    }

    private static let allSlots = ["breakfast", "lunch", "dinner"]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: SMSpacing.lg) {
                    weekPicker

                    if let week = displayedWeek {
                        todaySection(week)
                        tomorrowSection(week)
                        restOfWeekSection(week)
                        groceryBar(week)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, SMSpacing.lg)
                .padding(.bottom, 80)
            }
            .background(SMColor.surface)
            .refreshable {
                await appState.refreshWeek()
                await loadAvailableWeeks()
            }

            AIFloatingButton {
                if appState.currentWeek == nil {
                    Task { await createWeekAndShowPlanner() }
                } else {
                    showingAIPlanner = true
                }
            }
            .padding(.trailing, SMSpacing.xl)
            .padding(.bottom, SMSpacing.xl)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("SimmerSmith")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: SMSpacing.lg) {
                    Button { showingActivity = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    .accessibilityLabel("View week activity")

                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .confirmationDialog(
            selectedMealForAction?.recipeName ?? "Meal",
            isPresented: Binding(
                get: { selectedMealForAction != nil },
                set: { if !$0 { selectedMealForAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let meal = selectedMealForAction {
                if meal.recipeId != nil {
                    Button("View Recipe") {
                        navigatingToRecipeID = meal.recipeId
                    }
                }
                Button("Edit Name") {
                    renameText = meal.recipeName
                    renamingMeal = meal
                }
                Button("Edit Notes") {
                    editingMeal = meal
                }
                Button("Mark as Eating Out") {
                    markEatingOut(meal)
                }
                Button("Remove", role: .destructive) {
                    removeMeal(meal)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .navigationDestination(item: $navigatingToRecipeID) { recipeID in
            RecipeDetailView(recipeID: recipeID)
        }
        .sheet(item: $editingMeal) { meal in
            MealNoteEditor(meal: meal) { newNotes in
                await updateMealNotes(meal, notes: newNotes)
            }
        }
        .sheet(isPresented: $showingActivity) {
            NavigationStack { ActivityView() }
        }
        .sheet(isPresented: $showingGrocery) {
            NavigationStack { GroceryView() }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showingAIPlanner) {
            aiPlannerSheet
        }
        .sheet(isPresented: Binding(
            get: { quickAddSlot != nil },
            set: { if !$0 { quickAddSlot = nil } }
        )) {
            if let info = quickAddSlot {
                MealQuickAddSheet(
                    dayName: info.dayName,
                    mealDate: info.mealDate,
                    slot: info.slot
                ) { mealName in
                    await addQuickMeal(
                        dayName: info.dayName,
                        mealDate: info.mealDate,
                        slot: info.slot,
                        recipeName: mealName
                    )
                }
            }
        }
        .alert("Rename Meal", isPresented: Binding(
            get: { renamingMeal != nil },
            set: { if !$0 { renamingMeal = nil } }
        )) {
            TextField("Meal name", text: $renameText)
            Button("Save") {
                if let meal = renamingMeal {
                    Task { await renameMeal(meal, newName: renameText) }
                }
            }
            Button("Cancel", role: .cancel) {
                renamingMeal = nil
            }
        }
        .task {
            await loadAvailableWeeks()
        }
    }

    // MARK: - Week Picker

    @ViewBuilder
    private var weekPicker: some View {
        if !availableWeeks.isEmpty {
            VStack(spacing: SMSpacing.sm) {
                HStack(spacing: SMSpacing.sm) {
                    Button {
                        navigateToPreviousWeek()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(SMColor.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: SMSpacing.sm) {
                                ForEach(availableWeeks) { week in
                                    let isSelected = isWeekSelected(week)
                                    Button {
                                        selectWeek(week)
                                    } label: {
                                        Text(weekPillLabel(for: week.weekStart))
                                            .font(SMFont.label)
                                            .foregroundStyle(isSelected ? SMColor.surface : SMColor.textSecondary)
                                            .padding(.horizontal, SMSpacing.md)
                                            .padding(.vertical, SMSpacing.sm)
                                            .background(isSelected ? SMColor.primary : SMColor.surfaceElevated)
                                            .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .id(week.weekId)
                                }
                            }
                            .padding(.horizontal, SMSpacing.xs)
                        }
                        .onChange(of: displayedWeekStart) {
                            if let selectedID = selectedWeekID {
                                withAnimation {
                                    proxy.scrollTo(selectedID, anchor: .center)
                                }
                            }
                        }
                        .onAppear {
                            if let selectedID = selectedWeekID {
                                proxy.scrollTo(selectedID, anchor: .center)
                            }
                        }
                    }

                    Button {
                        navigateToNextWeek()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(SMColor.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if !isViewingCurrentWeek {
                    Button {
                        snapToCurrentWeek()
                    } label: {
                        HStack(spacing: SMSpacing.xs) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.caption2)
                            Text("This Week")
                                .font(SMFont.label)
                        }
                        .foregroundStyle(SMColor.primary)
                        .padding(.horizontal, SMSpacing.md)
                        .padding(.vertical, SMSpacing.xs)
                        .background(SMColor.primary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, SMSpacing.sm)
        }
    }

    // MARK: - Today Section

    @ViewBuilder
    private func todaySection(_ week: WeekSnapshot) -> some View {
        let todayMeals = isViewingCurrentWeek
            ? week.meals.filter { Calendar.current.isDateInToday($0.mealDate) }
            : mealsForFirstDay(of: week)

        let sectionTitle = isViewingCurrentWeek ? "Today" : firstDayName(of: week)
        let sectionDate: Date = isViewingCurrentWeek ? Date() : week.weekStart

        VStack(alignment: .leading, spacing: SMSpacing.md) {
            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                Text(sectionTitle)
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)

                Text(sectionDate.formatted(date: .abbreviated, time: .omitted))
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textSecondary)
            }
            .padding(.top, SMSpacing.sm)

            if todayMeals.isEmpty {
                VStack(spacing: SMSpacing.sm) {
                    Text("Nothing planned")
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textSecondary)
                    Text("Tap the sparkle button to plan meals with AI")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SMSpacing.xl)
            } else {
                ForEach(todayMeals) { meal in
                    TodayMealCard(
                        meal: meal,
                        recipe: recipeSummary(for: meal),
                        onTap: { selectedMealForAction = meal }
                    )
                }
            }

            // Empty slot placeholders
            let filledSlots = Set(todayMeals.map(\.slot))
            let dayNameForSlots = todayMeals.first?.dayName ?? sectionTitle
            let dateForSlots = todayMeals.first?.mealDate ?? sectionDate
            ForEach(Self.allSlots.filter { !filledSlots.contains($0) }, id: \.self) { slot in
                emptySlotButton(dayName: dayNameForSlots, mealDate: dateForSlots, slot: slot)
            }
        }
    }

    // MARK: - Tomorrow Section

    private func tomorrowMeals(for week: WeekSnapshot) -> [WeekMeal] {
        if isViewingCurrentWeek {
            return week.meals.filter { Calendar.current.isDateInTomorrow($0.mealDate) }
        } else {
            return mealsForSecondDay(of: week)
        }
    }

    private func tomorrowTitle(for week: WeekSnapshot) -> String {
        isViewingCurrentWeek ? "Tomorrow" : secondDayName(of: week)
    }

    @ViewBuilder
    private func tomorrowSection(_ week: WeekSnapshot) -> some View {
        let meals = tomorrowMeals(for: week)
        let title = tomorrowTitle(for: week)

        if !meals.isEmpty || !isViewingCurrentWeek {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                Text(title)
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)

                ForEach(meals) { meal in
                    CompactMealCard(meal: meal) {
                        selectedMealForAction = meal
                    }
                }

                // Empty slot placeholders
                tomorrowEmptySlots(week: week, meals: meals)
            }
        }
    }

    @ViewBuilder
    private func tomorrowEmptySlots(week: WeekSnapshot, meals: [WeekMeal]) -> some View {
        let filledSlots = Set(meals.map(\.slot))
        if let firstMeal = meals.first {
            ForEach(Self.allSlots.filter { !filledSlots.contains($0) }, id: \.self) { slot in
                emptySlotButton(dayName: firstMeal.dayName, mealDate: firstMeal.mealDate, slot: slot)
            }
        } else if !isViewingCurrentWeek {
            let dayDate = Calendar.current.date(byAdding: .day, value: 1, to: week.weekStart) ?? week.weekStart
            let dayName = secondDayName(of: week)
            ForEach(Self.allSlots, id: \.self) { slot in
                emptySlotButton(dayName: dayName, mealDate: dayDate, slot: slot)
            }
        }
    }

    // MARK: - Rest of Week

    private func remainingMeals(for week: WeekSnapshot) -> [WeekMeal] {
        if isViewingCurrentWeek {
            let calendar = Calendar.current
            return week.meals.filter {
                !calendar.isDateInToday($0.mealDate) && !calendar.isDateInTomorrow($0.mealDate)
            }
        } else {
            let sortedDates = uniqueSortedDates(of: week)
            let skipDates = Set(sortedDates.prefix(2))
            return week.meals.filter { !skipDates.contains(Calendar.current.startOfDay(for: $0.mealDate)) }
        }
    }

    @ViewBuilder
    private func restOfWeekSection(_ week: WeekSnapshot) -> some View {
        let remaining = remainingMeals(for: week)

        if !remaining.isEmpty {
            let grouped = groupedMeals(from: remaining)

            ForEach(grouped, id: \.dayName) { day in
                VStack(alignment: .leading, spacing: SMSpacing.sm) {
                    Text(day.dayName)
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.primary)

                    ForEach(day.meals) { meal in
                        CompactMealCard(meal: meal) {
                            selectedMealForAction = meal
                        }
                    }

                    // Empty slot placeholders for each day
                    let filledSlots = Set(day.meals.map(\.slot))
                    if let firstMeal = day.meals.first {
                        ForEach(Self.allSlots.filter { !filledSlots.contains($0) }, id: \.self) { slot in
                            emptySlotButton(dayName: firstMeal.dayName, mealDate: firstMeal.mealDate, slot: slot)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty Slot Button

    private func emptySlotButton(dayName: String, mealDate: Date, slot: String) -> some View {
        Button {
            quickAddSlot = (dayName: dayName, mealDate: mealDate, slot: slot)
        } label: {
            HStack(spacing: SMSpacing.md) {
                Text(slot.capitalized)
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
                    .frame(width: 56, alignment: .leading)

                HStack(spacing: SMSpacing.xs) {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                    Text("Add \(slot)")
                }
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textTertiary)

                Spacer()
            }
            .padding(.horizontal, SMSpacing.md)
            .padding(.vertical, SMSpacing.sm)
            .background(SMColor.surfaceCard.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous)
                    .strokeBorder(SMColor.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grocery Bar

    @ViewBuilder
    private func groceryBar(_ week: WeekSnapshot) -> some View {
        if !week.groceryItems.isEmpty {
            Button { showingGrocery = true } label: {
                HStack {
                    Image(systemName: "cart.fill")
                        .foregroundStyle(SMColor.primary)
                    Text("\(week.groceryItems.count) grocery items")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textPrimary)
                    Spacer()
                    Text("View list")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.primary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(SMColor.primary)
                }
                .padding(SMSpacing.lg)
                .background(SMColor.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                        .strokeBorder(SMColor.primary.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: SMSpacing.xl) {
            Spacer()
                .frame(height: 80)

            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(SMColor.primary.opacity(0.6))

            VStack(spacing: SMSpacing.sm) {
                Text("No Week Yet")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)
                Text("Tap the sparkle button to plan your first week with AI.")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SMSpacing.xxl)
    }

    // MARK: - AI Planner Sheet

    private var aiPlannerSheet: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                VStack(spacing: SMSpacing.xl) {
                    VStack(spacing: SMSpacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 36))
                            .foregroundStyle(SMColor.primary)

                        Text("Plan My Week")
                            .font(SMFont.display)
                            .foregroundStyle(SMColor.textPrimary)

                        Text("Describe what you'd like to eat and AI will generate a full week of meals with recipes.")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, SMSpacing.xl)

                    TextField(
                        "e.g., healthy meals for two, quick dinners, lots of veggies...",
                        text: $aiPrompt,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .padding(SMSpacing.lg)
                    .background(SMColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    .foregroundStyle(SMColor.textPrimary)

                    if let error = generationError {
                        Text(error)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.destructive)
                            .multilineTextAlignment(.center)
                    }

                    Button { Task { await generatePlan() } } label: {
                        if isGenerating {
                            HStack(spacing: SMSpacing.sm) {
                                ProgressView()
                                    .tint(SMColor.surface)
                                Text("Generating meals...")
                                    .font(SMFont.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SMSpacing.lg)
                        } else {
                            Label("Generate Week", systemImage: "wand.and.stars")
                                .font(SMFont.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SMSpacing.lg)
                        }
                    }
                    .foregroundStyle(isGenerating ? SMColor.textSecondary : .white)
                    .background(isGenerating ? SMColor.surfaceElevated : SMColor.primary)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    .disabled(isGenerating)

                    Spacer()
                }
                .padding(.horizontal, SMSpacing.xl)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAIPlanner = false }
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Meal Edit Actions

    private func markEatingOut(_ meal: WeekMeal) {
        guard let week = displayedWeek else { return }
        Task {
            var meals = week.meals.map { m in
                MealUpdateRequest(
                    mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                    slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                    servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                    notes: m.notes, approved: m.approved
                )
            }
            if let idx = meals.firstIndex(where: { $0.mealId == meal.mealId }) {
                meals[idx] = MealUpdateRequest(
                    mealId: meal.mealId, dayName: meal.dayName,
                    mealDate: meal.mealDate, slot: meal.slot,
                    recipeName: "Eating Out", approved: true
                )
            }
            let updated = try? await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated ?? browsedWeek }
        }
    }

    private func removeMeal(_ meal: WeekMeal) {
        guard let week = displayedWeek else { return }
        Task {
            let meals = week.meals
                .filter { $0.mealId != meal.mealId }
                .map { m in
                    MealUpdateRequest(
                        mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                        slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                        servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                        notes: m.notes, approved: m.approved
                    )
                }
            let updated = try? await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated ?? browsedWeek }
        }
    }

    private func updateMealNotes(_ meal: WeekMeal, notes: String) async {
        guard let week = displayedWeek else { return }
        var meals = week.meals.map { m in
            MealUpdateRequest(
                mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                notes: m.notes, approved: m.approved
            )
        }
        if let idx = meals.firstIndex(where: { $0.mealId == meal.mealId }) {
            meals[idx] = MealUpdateRequest(
                mealId: meal.mealId, dayName: meal.dayName,
                mealDate: meal.mealDate, slot: meal.slot,
                recipeId: meal.recipeId, recipeName: meal.recipeName,
                servings: meal.servings, scaleMultiplier: meal.scaleMultiplier,
                notes: notes, approved: meal.approved
            )
        }
        let updated = try? await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
        if !isViewingCurrentWeek { browsedWeek = updated ?? browsedWeek }
    }

    private func renameMeal(_ meal: WeekMeal, newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let week = displayedWeek else { return }
        var meals = week.meals.map { m in
            MealUpdateRequest(
                mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                notes: m.notes, approved: m.approved
            )
        }
        if let idx = meals.firstIndex(where: { $0.mealId == meal.mealId }) {
            meals[idx] = MealUpdateRequest(
                mealId: meal.mealId, dayName: meal.dayName,
                mealDate: meal.mealDate, slot: meal.slot,
                recipeId: meal.recipeId, recipeName: trimmed,
                servings: meal.servings, scaleMultiplier: meal.scaleMultiplier,
                notes: meal.notes, approved: meal.approved
            )
        }
        let updated = try? await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
        if !isViewingCurrentWeek { browsedWeek = updated ?? browsedWeek }
    }

    private func addQuickMeal(dayName: String, mealDate: Date, slot: String, recipeName: String) async {
        guard let week = displayedWeek else { return }
        var meals = week.meals.map { m in
            MealUpdateRequest(
                mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                notes: m.notes, approved: m.approved
            )
        }
        meals.append(MealUpdateRequest(
            dayName: dayName, mealDate: mealDate, slot: slot,
            recipeName: recipeName
        ))
        let updated = try? await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
        if !isViewingCurrentWeek { browsedWeek = updated ?? browsedWeek }
    }

    // MARK: - Actions

    private func createWeekAndShowPlanner() async {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!

        do {
            _ = try await appState.createWeek(weekStart: monday)
            await appState.refreshWeek()
            await loadAvailableWeeks()
            showingAIPlanner = true
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    private func generatePlan() async {
        guard let weekID = appState.currentWeek?.weekId else { return }
        isGenerating = true
        generationError = nil
        do {
            _ = try await appState.generateWeekFromAI(weekID: weekID, prompt: aiPrompt)
            showingAIPlanner = false
        } catch {
            generationError = error.localizedDescription
        }
        isGenerating = false
    }

    // MARK: - Week Navigation

    private func loadAvailableWeeks() async {
        do {
            availableWeeks = try await appState.fetchWeeks(limit: 12)
        } catch {
            // Silently fail — picker just won't show
        }
    }

    private var selectedWeekID: String? {
        if let start = displayedWeekStart {
            return availableWeeks.first { Calendar.current.isDate($0.weekStart, inSameDayAs: start) }?.weekId
        }
        return availableWeeks.first { isCurrentWeek($0) }?.weekId
    }

    private func isWeekSelected(_ week: WeekSummary) -> Bool {
        if let start = displayedWeekStart {
            return Calendar.current.isDate(week.weekStart, inSameDayAs: start)
        }
        return isCurrentWeek(week)
    }

    private func isCurrentWeek(_ week: WeekSummary) -> Bool {
        guard let currentWeek = appState.currentWeek else { return false }
        return week.weekId == currentWeek.weekId
    }

    private func selectWeek(_ week: WeekSummary) {
        if isCurrentWeek(week) {
            snapToCurrentWeek()
            return
        }
        displayedWeekStart = week.weekStart
        browsedWeek = nil
        Task {
            do {
                browsedWeek = try await appState.fetchWeekByStart(week.weekStart)
            } catch {
                appState.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func snapToCurrentWeek() {
        displayedWeekStart = nil
        browsedWeek = nil
    }

    private func navigateToPreviousWeek() {
        let sortedWeeks = availableWeeks.sorted { $0.weekStart < $1.weekStart }
        guard !sortedWeeks.isEmpty else { return }

        if let currentIdx = currentSelectedIndex(in: sortedWeeks), currentIdx > 0 {
            selectWeek(sortedWeeks[currentIdx - 1])
        }
    }

    private func navigateToNextWeek() {
        let sortedWeeks = availableWeeks.sorted { $0.weekStart < $1.weekStart }
        guard !sortedWeeks.isEmpty else { return }

        if let currentIdx = currentSelectedIndex(in: sortedWeeks), currentIdx < sortedWeeks.count - 1 {
            selectWeek(sortedWeeks[currentIdx + 1])
        }
    }

    private func currentSelectedIndex(in sortedWeeks: [WeekSummary]) -> Int? {
        if let start = displayedWeekStart {
            return sortedWeeks.firstIndex { Calendar.current.isDate($0.weekStart, inSameDayAs: start) }
        }
        return sortedWeeks.firstIndex { isCurrentWeek($0) }
    }

    private func weekPillLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    // MARK: - Helpers

    private func recipeSummary(for meal: WeekMeal) -> RecipeSummary? {
        guard let recipeId = meal.recipeId else { return nil }
        return appState.recipes.first { $0.recipeId == recipeId }
    }

    private func groupedMeals(from meals: [WeekMeal]) -> [(dayName: String, meals: [WeekMeal])] {
        let grouped = Dictionary(grouping: meals, by: \.dayName)
        return grouped
            .map { key, value in
                (key, value.sorted { ($0.mealDate, $0.slot) < ($1.mealDate, $1.slot) })
            }
            .sorted { ($0.meals.first?.mealDate ?? .distantFuture) < ($1.meals.first?.mealDate ?? .distantFuture) }
    }

    private func uniqueSortedDates(of week: WeekSnapshot) -> [Date] {
        let calendar = Calendar.current
        let dates = Set(week.meals.map { calendar.startOfDay(for: $0.mealDate) })
        return dates.sorted()
    }

    private func mealsForFirstDay(of week: WeekSnapshot) -> [WeekMeal] {
        let dates = uniqueSortedDates(of: week)
        guard let first = dates.first else { return [] }
        return week.meals.filter { Calendar.current.isDate($0.mealDate, inSameDayAs: first) }
    }

    private func mealsForSecondDay(of week: WeekSnapshot) -> [WeekMeal] {
        let dates = uniqueSortedDates(of: week)
        guard dates.count >= 2 else { return [] }
        return week.meals.filter { Calendar.current.isDate($0.mealDate, inSameDayAs: dates[1]) }
    }

    private func firstDayName(of week: WeekSnapshot) -> String {
        let meals = mealsForFirstDay(of: week)
        return meals.first?.dayName ?? dayNameFromDate(week.weekStart)
    }

    private func secondDayName(of week: WeekSnapshot) -> String {
        let meals = mealsForSecondDay(of: week)
        if let name = meals.first?.dayName { return name }
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: week.weekStart) ?? week.weekStart
        return dayNameFromDate(nextDay)
    }

    private func dayNameFromDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
