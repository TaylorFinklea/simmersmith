import SwiftUI
import SimmerSmithKit

struct WeekView: View {
    @Environment(AppState.self) private var appState
    @Environment(AIAssistantCoordinator.self) private var aiCoordinator

    @State private var selectedMealForAction: WeekMeal?
    @State private var pickedSeasonalItem: InSeasonItem?
    @State private var editingMeal: WeekMeal?
    @State private var navigatingToRecipeID: String?
    @State private var showingActivity = false
    @State private var showingGrocery = false
    @State private var showingSettings = false

    // Week navigation
    @State private var displayedWeekStart: Date?
    @State private var availableWeeks: [WeekSummary] = []
    @State private var browsedWeek: WeekSnapshot?

    // Meal quick-add
    @State private var quickAddSlot: (dayName: String, mealDate: Date, slot: String)?

    // Meal rename
    @State private var renamingMeal: WeekMeal?
    @State private var renameText: String = ""

    // Meal move
    @State private var movingMeal: WeekMeal?

    // Link to recipe
    @State private var linkRecipeMeal: WeekMeal?

    // AI recipe creation
    @State private var aiCreateMeal: WeekMeal?
    @State private var isCreatingRecipe = false

    // Approval
    @State private var isApprovingAll = false
    @State private var showApprovalConfirmation = false

    // Meal feedback
    @State private var feedbackMeal: WeekMeal?

    // Day nutrition sheet
    @State private var nutritionDay: (dayName: String, date: Date, meals: [WeekMeal], totals: MacroBreakdown)?

    // Rebalance-this-day
    @State private var rebalancingDayKey: String?

    private var displayedWeek: WeekSnapshot? {
        if displayedWeekStart != nil {
            return browsedWeek ?? appState.currentWeek
        }
        return appState.currentWeek
    }

    private var isViewingCurrentWeek: Bool {
        displayedWeekStart == nil
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: SMSpacing.lg) {
                    weekPicker

                    InSeasonStrip(pickedItem: $pickedSeasonalItem)

                    if let week = displayedWeek {
                        approveAllBar(week)
                        todayHero(week)
                        daysSection(week)
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
                await appState.forceRefreshSeasonalProduce()
            }
        }
        .task {
            await appState.refreshSeasonalProduceIfStale()
        }
        .sheet(item: $pickedSeasonalItem) { item in
            InSeasonDetailSheet(item: item)
        }
        .overlay(alignment: .top) {
            if isPlanningChatActive {
                activeChatChip
            }
        }
        .overlay(alignment: .top) {
            if let message = appState.lastErrorMessage, !message.isEmpty {
                HStack(alignment: .top, spacing: SMSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SMColor.destructive)
                    Text(message)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        appState.lastErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SMColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss error")
                }
                .padding(SMSpacing.md)
                .background(SMColor.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                        .strokeBorder(SMColor.destructive.opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                .padding(.horizontal, SMSpacing.md)
                .padding(.top, SMSpacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.lastErrorMessage)
        .onAppear { publishContext() }
        .onChange(of: appState.currentWeek?.weekId) { _, _ in publishContext() }
        .onChange(of: displayedWeekStart) { _, _ in publishContext() }
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
                    Button("Rate This Meal") {
                        feedbackMeal = meal
                    }
                }
                Button("Edit Name") {
                    renameText = meal.recipeName
                    renamingMeal = meal
                }
                Button("Edit Notes") {
                    editingMeal = meal
                }
                Button("Move to...") {
                    movingMeal = meal
                }
                if meal.recipeId == nil {
                    Button("Link to Recipe") {
                        linkRecipeMeal = meal
                    }
                    Button("Create Recipe with AI") {
                        aiCreateMeal = meal
                    }
                }
                if meal.approved {
                    Button("Unapprove") {
                        Task { await toggleMealApproval(meal, approved: false) }
                    }
                } else {
                    Button("Approve") {
                        Task { await toggleMealApproval(meal, approved: true) }
                    }
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
        .sheet(isPresented: Binding(
            get: { quickAddSlot != nil },
            set: { if !$0 { quickAddSlot = nil } }
        )) {
            if let info = quickAddSlot {
                MealQuickAddSheet(
                    dayName: info.dayName,
                    mealDate: info.mealDate,
                    slot: info.slot,
                    recipes: appState.recipes,
                    onSaveFreeform: { mealName in
                        await addQuickMeal(
                            dayName: info.dayName,
                            mealDate: info.mealDate,
                            slot: info.slot,
                            recipeName: mealName,
                            recipeId: nil
                        )
                    },
                    onSaveRecipe: { recipe in
                        await addQuickMeal(
                            dayName: info.dayName,
                            mealDate: info.mealDate,
                            slot: info.slot,
                            recipeName: recipe.name,
                            recipeId: recipe.recipeId
                        )
                    }
                )
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
        .sheet(item: $movingMeal) { meal in
            if let week = displayedWeek {
                MealMoveSheet(meal: meal, week: week) { newDayName, newDate, newSlot in
                    await moveMeal(meal, toDayName: newDayName, date: newDate, slot: newSlot)
                }
            }
        }
        .sheet(item: $linkRecipeMeal) { meal in
            RecipePickerSheet(meal: meal, recipes: appState.recipes) { recipe in
                await linkMealToRecipe(meal, recipe: recipe)
            }
        }
        .sheet(item: $aiCreateMeal) { meal in
            AIRecipeCreateSheet(mealName: meal.recipeName) { recipe in
                await linkMealToSavedRecipe(meal, recipeId: recipe.recipeId, recipeName: recipe.name)
            }
        }
        .sheet(item: $feedbackMeal) { meal in
            FeedbackComposerView(title: meal.recipeName) { sentiment, notes in
                try await appState.submitMealFeedback(for: meal, sentiment: sentiment, notes: notes)
            }
        }
        .sheet(isPresented: Binding(
            get: { nutritionDay != nil },
            set: { if !$0 { nutritionDay = nil } }
        )) {
            if let day = nutritionDay {
                DayNutritionSheet(
                    dayName: day.dayName,
                    date: day.date,
                    meals: day.meals,
                    totals: day.totals
                )
            }
        }
        .task {
            await loadAvailableWeeks()
        }
    }

    // MARK: - Week Picker

    @ViewBuilder
    private var weekPicker: some View {
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
                .disabled(navigationAnchor == nil)
                .accessibilityLabel("Previous week")

                VStack(spacing: 2) {
                    Text(displayedWeekRangeLabel())
                        .font(SMFont.subheadline.weight(.semibold))
                        .foregroundStyle(SMColor.textPrimary)
                    if let relative = displayedWeekRelativeLabel() {
                        Text(relative)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SMSpacing.xs)

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
                .disabled(navigationAnchor == nil)
                .accessibilityLabel("Next week")
            }

            if !availableWeeks.isEmpty {
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

    // MARK: - Day helpers (see `DayKey` for the shared implementation)

    private func mealsForDate(_ date: Date, in week: WeekSnapshot) -> [WeekMeal] {
        let key = DayKey.server(date)
        return week.meals
            .filter { DayKey.server($0.mealDate) == key }
            .sorted { slotOrder($0.slot) < slotOrder($1.slot) }
    }

    // MARK: - Today Hero (always at the top)

    @ViewBuilder
    private func todayHero(_ week: WeekSnapshot) -> some View {
        let weekDates = (0..<7).compactMap {
            DayKey.utcCalendar.date(byAdding: .day, value: $0, to: week.weekStart)
        }

        if let todayDate = weekDates.first(where: { DayKey.isToday($0) }) {
            let meals = mealsForDate(todayDate, in: week)
            let dayName = meals.first?.dayName ?? DayKey.weekdayName(todayDate)
            let totals = dayMacros(for: todayDate, meals: meals, week: week)

            VStack(alignment: .leading, spacing: SMSpacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: SMSpacing.xs) {
                        Text("Today")
                            .font(SMFont.display)
                            .foregroundStyle(SMColor.textPrimary)

                        Text(DayKey.shortMonthDay(todayDate) + " · " + dayName)
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    Spacer()
                    if appState.profile?.dietaryGoal != nil || !totals.isEmpty {
                        Button {
                            nutritionDay = (dayName: dayName, date: todayDate, meals: meals, totals: totals)
                        } label: {
                            MacroRing(macros: totals, goal: appState.profile?.dietaryGoal, compact: false)
                        }
                        .buttonStyle(.plain)
                    }
                }

                renderSlots(for: todayDate, dayName: dayName, meals: meals, style: .hero)
            }
            .padding(.top, SMSpacing.sm)
        }
    }

    // MARK: - Days Grid (all 7 days of the week)

    private func weekDays(of week: WeekSnapshot) -> [(date: Date, dayName: String)] {
        let cal = DayKey.utcCalendar
        let start = cal.startOfDay(for: week.weekStart)
        return (0..<7).map { offset in
            let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
            let name = DayKey.weekdayName(date)
            return (date, name)
        }
    }

    private var configuredSlots: [String] {
        let raw = appState.profile?.settings["default_slots"] ?? ""
        let parts = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? ["breakfast", "lunch", "dinner"] : parts
    }

    @ViewBuilder
    private func daysSection(_ week: WeekSnapshot) -> some View {
        let days = weekDays(of: week)
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("This Week")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)

                Spacer()

                if let weekly = week.weeklyTotals, let goal = appState.profile?.dietaryGoal {
                    let weeklyTarget = goal.dailyCalories * 7
                    let pctOff = weeklyTarget > 0 ? Int(((weekly.calories - Double(weeklyTarget)) / Double(weeklyTarget)) * 100) : 0
                    let inRange = abs(pctOff) <= 10
                    HStack(spacing: SMSpacing.xs) {
                        Image(systemName: inRange ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.caption)
                        Text("Week: \(Int(weekly.calories)) / \(weeklyTarget) cal")
                            .font(SMFont.caption.monospacedDigit())
                    }
                    .foregroundStyle(inRange ? SMColor.success : .orange)
                    .padding(.horizontal, SMSpacing.sm)
                    .padding(.vertical, SMSpacing.xs)
                    .background((inRange ? SMColor.success : Color.orange).opacity(0.12), in: Capsule())
                }
            }
            .padding(.top, SMSpacing.md)

            ForEach(days, id: \.date) { day in
                daySection(week: week, date: day.date, dayName: day.dayName)
            }
        }
    }

    @ViewBuilder
    private func daySection(week: WeekSnapshot, date: Date, dayName: String) -> some View {
        let meals = mealsForDate(date, in: week)
        let isToday = DayKey.isToday(date)
        let totals = dayMacros(for: date, meals: meals, week: week)
        let showMacros = !totals.isEmpty && (appState.profile?.dietaryGoal != nil || totals.calories > 0)

        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: SMSpacing.sm) {
                Text(dayName)
                    .font(SMFont.subheadline)
                    .foregroundStyle(isToday ? SMColor.textPrimary : SMColor.primary)

                Text(DayKey.shortMonthDay(date))
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)

                if isToday {
                    Text("Today")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.primary)
                        .padding(.horizontal, SMSpacing.xs)
                        .padding(.vertical, 2)
                        .background(SMColor.primary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                Button {
                    publishFocus(date: date, dayName: dayName)
                    aiCoordinator.present()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(SMColor.aiPurple)
                        .padding(6)
                        .background(SMColor.aiPurple.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask AI about \(dayName)")

                if showMacros {
                    Button {
                        nutritionDay = (dayName: dayName, date: date, meals: meals, totals: totals)
                    } label: {
                        MacroRing(macros: totals, goal: appState.profile?.dietaryGoal)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, SMSpacing.xs)

            renderSlots(for: date, dayName: dayName, meals: meals, style: .compact)

            rebalanceBanner(for: date, dayName: dayName, totals: totals)
        }
    }

    @ViewBuilder
    private func rebalanceBanner(for date: Date, dayName: String, totals: MacroBreakdown) -> some View {
        if let goal = appState.profile?.dietaryGoal,
           goal.dailyCalories > 0,
           !totals.isEmpty {
            let target = Double(goal.dailyCalories)
            let drift = (totals.calories - target) / target
            if abs(drift) >= 0.15 {
                let dayKey = DayKey.server(date)
                let isRebalancing = rebalancingDayKey == dayKey
                let direction = drift > 0 ? "over" : "under"
                let diff = abs(Int(totals.calories - target))
                Button {
                    Task { await rebalance(date: date, key: dayKey) }
                } label: {
                    HStack(spacing: SMSpacing.sm) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(SMColor.aiPurple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isRebalancing ? "Rebalancing \(dayName)…" : "\(dayName) is \(diff) cal \(direction) target")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textPrimary)
                            Text(isRebalancing ? "Asking AI for replacement meals" : "Tap to have AI replan this day")
                                .font(.caption2)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                        Spacer()
                        if isRebalancing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                    .padding(SMSpacing.sm)
                    .background(SMColor.aiPurple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous)
                            .strokeBorder(SMColor.aiPurple.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRebalancing)
            }
        }
    }

    private func rebalance(date: Date, key: String) async {
        guard let week = displayedWeek else { return }
        rebalancingDayKey = key
        defer { rebalancingDayKey = nil }
        do {
            let updated = try await appState.rebalanceDay(weekID: week.weekId, mealDate: date)
            if !isViewingCurrentWeek { browsedWeek = updated }
        } catch SimmerSmithAPIError.usageLimitReached(let action, let limit, let used, _) {
            appState.presentPaywall(.limitReached(action: action, used: used, limit: limit))
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    /// Sum per-meal macros for a given day. Prefers the backend's per-meal
    /// numbers (already scaled by `servings * scale_multiplier`) when
    /// available, and falls back to the backend's per-day totals.
    private func dayMacros(for date: Date, meals: [WeekMeal], week: WeekSnapshot) -> MacroBreakdown {
        let fromMeals = meals.reduce(MacroBreakdown()) { acc, meal in
            guard let m = meal.macros else { return acc }
            return MacroBreakdown(
                calories: acc.calories + m.calories,
                proteinG: acc.proteinG + m.proteinG,
                carbsG: acc.carbsG + m.carbsG,
                fatG: acc.fatG + m.fatG,
                fiberG: acc.fiberG + m.fiberG
            )
        }
        if !fromMeals.isEmpty { return fromMeals }
        if let daily = week.nutritionTotals.first(where: { DayKey.isSameServerDay($0.mealDate, date) }) {
            return daily.macros
        }
        return MacroBreakdown()
    }

    private enum SlotStyle {
        case hero
        case compact
    }

    @ViewBuilder
    private func renderSlots(for date: Date, dayName: String, meals: [WeekMeal], style: SlotStyle) -> some View {
        let filledSlots = Set(meals.map(\.slot))
        let slots = configuredSlots + meals.map(\.slot).filter { !configuredSlots.contains($0) }
        let uniqueSlots = Array(NSOrderedSet(array: slots)) as? [String] ?? configuredSlots

        ForEach(uniqueSlots, id: \.self) { slot in
            if let meal = meals.first(where: { $0.slot == slot }) {
                switch style {
                case .hero:
                    TodayMealCard(
                        meal: meal,
                        recipe: recipeSummary(for: meal),
                        onTap: { selectedMealForAction = meal }
                    )
                case .compact:
                    CompactMealCard(meal: meal) {
                        selectedMealForAction = meal
                    }
                }
            } else if !filledSlots.contains(slot) {
                emptySlotButton(dayName: dayName, mealDate: date, slot: slot)
            }
        }
    }

    private func slotOrder(_ slot: String) -> Int {
        switch slot.lowercased() {
        case "breakfast": return 0
        case "lunch": return 1
        case "dinner": return 2
        case "snack", "snacks": return 3
        default: return 99
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 80, alignment: .leading)

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

    // MARK: - Approve All Bar

    @ViewBuilder
    private func approveAllBar(_ week: WeekSnapshot) -> some View {
        let unapprovedCount = week.meals.filter { !$0.approved }.count
        if unapprovedCount > 0 {
            Button {
                Task { await approveAllMeals() }
            } label: {
                HStack(spacing: SMSpacing.md) {
                    if isApprovingAll {
                        ProgressView()
                            .tint(SMColor.success)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(SMColor.success)
                    }
                    Text("Approve All (\(unapprovedCount) unapproved)")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(SMColor.success)
                }
                .padding(SMSpacing.lg)
                .background(SMColor.success.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                        .strokeBorder(SMColor.success.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isApprovingAll)
        }

        if showApprovalConfirmation {
            HStack(spacing: SMSpacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SMColor.success)
                Text("Week approved!")
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.success)
            }
            .frame(maxWidth: .infinity)
            .padding(SMSpacing.lg)
            .background(SMColor.success.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
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
                Text("Tap the sparkle button to chat with the AI and plan your first week.")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SMSpacing.xxl)
    }

    // MARK: - Approval Actions

    private func approveAllMeals() async {
        guard let week = displayedWeek else { return }
        isApprovingAll = true
        do {
            let updated = try await appState.approveWeek(weekID: week.weekId)
            if !isViewingCurrentWeek { browsedWeek = updated }
            // Regenerate grocery list after approval
            let refreshed = try await appState.regenerateGrocery(weekID: week.weekId)
            if !isViewingCurrentWeek { browsedWeek = refreshed }
            withAnimation { showApprovalConfirmation = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { showApprovalConfirmation = false }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
        isApprovingAll = false
    }

    private func toggleMealApproval(_ meal: WeekMeal, approved: Bool) async {
        guard let week = displayedWeek else { return }
        var meals = week.meals.map { $0.asMealUpdateRequest() }
        if let idx = meals.firstIndex(where: { $0.mealId == meal.mealId }) {
            meals[idx] = MealUpdateRequest(
                mealId: meal.mealId, dayName: meal.dayName,
                mealDate: meal.mealDate, slot: meal.slot,
                recipeId: meal.recipeId, recipeName: meal.recipeName,
                servings: meal.servings, scaleMultiplier: meal.scaleMultiplier,
                notes: meal.notes, approved: approved
            )
        }
        do {
            let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Meal Edit Actions

    private func markEatingOut(_ meal: WeekMeal) {
        guard let week = displayedWeek else { return }
        selectedMealForAction = nil
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
            do {
                let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
                if !isViewingCurrentWeek { browsedWeek = updated }
            } catch {
                appState.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func removeMeal(_ meal: WeekMeal) {
        guard let week = displayedWeek else { return }
        selectedMealForAction = nil
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
            do {
                let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
                if !isViewingCurrentWeek { browsedWeek = updated }
            } catch {
                appState.lastErrorMessage = error.localizedDescription
            }
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
        do {
            let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
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
        do {
            let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    private func moveMeal(_ meal: WeekMeal, toDayName: String, date: Date, slot: String) async {
        guard let week = displayedWeek else { return }
        let calendar = Calendar.current
        let targetExisting = week.meals.first {
            calendar.isDate($0.mealDate, inSameDayAs: date) && $0.slot == slot
        }

        var meals = week.meals.map { m in
            MealUpdateRequest(
                mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                notes: m.notes, approved: m.approved
            )
        }

        // Move the source meal to the target slot
        if let srcIdx = meals.firstIndex(where: { $0.mealId == meal.mealId }) {
            meals[srcIdx] = MealUpdateRequest(
                mealId: meal.mealId, dayName: toDayName, mealDate: date,
                slot: slot, recipeId: meal.recipeId, recipeName: meal.recipeName,
                servings: meal.servings, scaleMultiplier: meal.scaleMultiplier,
                notes: meal.notes, approved: meal.approved
            )
        }

        // If there was a meal in the target slot, swap it to the source slot
        if let targetMeal = targetExisting,
           let tgtIdx = meals.firstIndex(where: { $0.mealId == targetMeal.mealId }) {
            meals[tgtIdx] = MealUpdateRequest(
                mealId: targetMeal.mealId, dayName: meal.dayName, mealDate: meal.mealDate,
                slot: meal.slot, recipeId: targetMeal.recipeId, recipeName: targetMeal.recipeName,
                servings: targetMeal.servings, scaleMultiplier: targetMeal.scaleMultiplier,
                notes: targetMeal.notes, approved: targetMeal.approved
            )
        }

        do {
            let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    private func linkMealToRecipe(_ meal: WeekMeal, recipe: RecipeSummary) async {
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
                recipeId: recipe.recipeId, recipeName: recipe.name,
                servings: meal.servings, scaleMultiplier: meal.scaleMultiplier,
                notes: meal.notes, approved: meal.approved
            )
        }
        do {
            let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    private func linkMealToSavedRecipe(_ meal: WeekMeal, recipeId: String, recipeName: String) async {
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
                recipeId: recipeId, recipeName: recipeName,
                servings: meal.servings, scaleMultiplier: meal.scaleMultiplier,
                notes: meal.notes, approved: meal.approved
            )
        }
        do {
            let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    private func addQuickMeal(dayName: String, mealDate: Date, slot: String, recipeName: String, recipeId: String?) async {
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
            recipeId: recipeId, recipeName: recipeName
        ))
        do {
            let updated = try await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
            if !isViewingCurrentWeek { browsedWeek = updated }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    private func publishContext() {
        let week = displayedWeek
        let context = AIPageContext(
            pageType: "week",
            pageLabel: week.map { "Week of \(DayKey.shortMonthDay($0.weekStart))" } ?? "Week",
            weekId: week?.weekId,
            weekStart: week.map { DayKey.server($0.weekStart) },
            weekStatus: week?.status,
            briefSummary: week.map {
                "\($0.meals.count) meals, status: \($0.status)."
            } ?? "No week yet."
        )
        aiCoordinator.updateContext(context)
    }

    private func publishFocus(date: Date, dayName: String) {
        let week = displayedWeek
        aiCoordinator.updateContext(
            AIPageContext(
                pageType: "week",
                pageLabel: "\(dayName) on this week",
                weekId: week?.weekId,
                weekStart: week.map { DayKey.server($0.weekStart) },
                weekStatus: week?.status,
                focusDate: DayKey.server(date),
                focusDayName: dayName
            )
        )
    }

    private var isPlanningChatActive: Bool {
        guard let weekID = appState.currentWeek?.weekId else { return false }
        return aiCoordinator.isSending && aiCoordinator.currentContext?.weekId == weekID
    }

    private var activeChatChip: some View {
        HStack(spacing: SMSpacing.sm) {
            ProgressView().controlSize(.small).tint(SMColor.aiPurple)
            Text("AI is editing this week…")
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textPrimary)
            Spacer()
            Button {
                aiCoordinator.present()
            } label: {
                Text("Open")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SMSpacing.md)
        .padding(.vertical, SMSpacing.sm)
        .background(SMColor.aiPurple.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .strokeBorder(SMColor.aiPurple.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .padding(.horizontal, SMSpacing.md)
        .padding(.top, SMSpacing.sm)
        .transition(.move(edge: .top).combined(with: .opacity))
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

    private func navigateToPreviousWeek() { navigateRelative(weeks: -1) }

    private func navigateToNextWeek() { navigateRelative(weeks: 1) }

    /// Calendar-app navigation: jump ±7 days from the displayed week and
    /// ensure-or-create the target week's server record. Server-side
    /// `POST /api/weeks` is idempotent (`create_or_get_week`), so a
    /// single call covers both "browse an existing week" and "stage a
    /// future week we haven't touched yet".
    ///
    /// All date math uses a UTC-anchored calendar to match the server's
    /// `week_start: date` field, which the iOS decoder lands on as
    /// UTC-midnight. A local-timezone calendar's `startOfDay` would
    /// shift the day boundary by the UTC offset and drift the lookup.
    private func navigateRelative(weeks: Int) {
        guard let anchor = navigationAnchor else { return }
        guard let target = Self.weekCalendar.date(byAdding: .day, value: weeks * 7, to: anchor) else { return }

        if let currentStart = appState.currentWeek?.weekStart,
           Self.weekCalendar.isDate(target, inSameDayAs: currentStart) {
            snapToCurrentWeek()
            return
        }

        displayedWeekStart = target
        browsedWeek = nil
        Task { await ensureWeek(at: target) }
    }

    /// Anchor for calendar arithmetic — the week we're currently looking
    /// at, falling back to the user's "current" server-side week.
    private var navigationAnchor: Date? {
        displayedWeekStart ?? appState.currentWeek?.weekStart
    }

    private func ensureWeek(at start: Date) async {
        do {
            let week = try await appState.createWeek(weekStart: start)
            browsedWeek = week
            await loadAvailableWeeks()
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    /// Server stores `week_start` as a UTC date; matching here keeps
    /// formatters and arithmetic from drifting across day boundaries.
    private static let weekCalendar: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private static let weekDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = weekCalendar
        formatter.timeZone = weekCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private func weekPillLabel(for date: Date) -> String {
        Self.weekDateFormatter.string(from: date)
    }

    private func displayedWeekRangeLabel() -> String {
        if let week = displayedWeek {
            return "\(Self.weekDateFormatter.string(from: week.weekStart)) – \(Self.weekDateFormatter.string(from: week.weekEnd))"
        }
        if let start = displayedWeekStart {
            let end = Self.weekCalendar.date(byAdding: .day, value: 6, to: start) ?? start
            return "\(Self.weekDateFormatter.string(from: start)) – \(Self.weekDateFormatter.string(from: end))"
        }
        return "No week yet"
    }

    private func displayedWeekRelativeLabel() -> String? {
        guard let currentStart = appState.currentWeek?.weekStart else { return nil }
        let anchor = displayedWeekStart ?? currentStart
        let diffDays = Self.weekCalendar.dateComponents([.day], from: currentStart, to: anchor).day ?? 0
        let weeks = diffDays / 7
        switch weeks {
        case 0: return "This week"
        case 1: return "Next week"
        case -1: return "Last week"
        case 2...: return "In \(weeks) weeks"
        case ...(-2): return "\(-weeks) weeks ago"
        default: return nil
        }
    }

    // MARK: - Helpers

    private func recipeSummary(for meal: WeekMeal) -> RecipeSummary? {
        guard let recipeId = meal.recipeId else { return nil }
        return appState.recipes.first { $0.recipeId == recipeId }
    }
}
