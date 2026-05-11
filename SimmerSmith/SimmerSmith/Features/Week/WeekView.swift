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

    // Manage sides on a meal (M26)
    @State private var sidesMeal: WeekMeal?

    // Build 57 — save leftovers from a meal to the freezer.
    @State private var leftoverSourceMeal: WeekMeal?

    // Build 61 — past days collapsed by default; track which past
    // dates the user has expanded. Keyed by `DayKey.server(date)` so
    // the comparison matches isPastDay/isToday consistency.
    @State private var expandedPastDays: Set<String> = []

    // Day nutrition sheet
    @State private var nutritionDay: (dayName: String, date: Date, meals: [WeekMeal], totals: MacroBreakdown)?

    /// Build 87 — plan-shopping sheet from the Week hero.
    @State private var showingPlanShopping = false

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
                    // Build 59 — Fusion Week IA. The page reads like a
                    // smith's planner: hero → in-season produce → tonight
                    // index card → "the week" with full per-day slots
                    // (multi-slot, snack support, paper styling, ember
                    // spine on today). Week picker / approve-all moved
                    // to the toolbar Menu so the scroll surface stays
                    // focused on the week content.
                    FuHero(
                        eyebrow: weekHeroEyebrow,
                        title: weekHeroTitle,
                        emberAccent: weekHeroEmberAccent,
                        trailing: AnyView(planShoppingTrailing)
                    )
                    .padding(.horizontal, -SMSpacing.lg) // FuHero applies its own 22pt inset; outer VStack inset is 16pt, so back it out
                    .contentShape(Rectangle())
                    .gesture(weekHeroSwipeGesture)
                    .accessibilityHint("Swipe left for next week, right for previous week.")

                    // Build 81 — Savanne: in-season takes up too much
                    // space on the current week. Hide here, surface
                    // it on Grocery instead. Future weeks (when the
                    // user is planning ahead) keep it as a planning aid.
                    if !isViewingCurrentWeek {
                        InSeasonStrip(pickedItem: $pickedSeasonalItem)
                    }

                    if let week = displayedWeek {
                        todayHero(week)
                        daysSection(week)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, SMSpacing.lg)
                .padding(.bottom, 80)
            }
            .paperBackground()
            .refreshable {
                await appState.refreshWeek()
                await loadAvailableWeeks()
                await appState.forceRefreshSeasonalProduce()
            }

            // Build 70 — configurable FAB. Default = ✨ Sparkle (open
            // Smith with Week context). Quick add or refresh as
            // alternatives.
            TabPrimaryFAB(page: .week, contextHint: "from Week", actions: [
                .quickAdd: {
                    let today = Date()
                    let dayName = today.formatted(.dateTime.weekday(.wide))
                    quickAddSlot = (
                        dayName: dayName,
                        mealDate: today,
                        slot: defaultSlotName()
                    )
                },
                .refresh: { Task { await appState.refreshWeek() } }
            ])
        }
        .task {
            await appState.refreshSeasonalProduceIfStale()
        }
        .sheet(item: $pickedSeasonalItem) { item in
            InSeasonDetailSheet(item: item)
        }
        // Build 87 — plan-shopping sheet entry from Week.
        .sheet(isPresented: $showingPlanShopping) {
            PlanShoppingSheet()
                .environment(appState)
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
            // Build 59 — Fusion Week IA. The toolbar absorbs the
            // controls that used to take up scroll real estate
            // (week picker, approve-all, in-season). Keeps the
            // scroll surface focused on "what am I cooking".
            ToolbarItem(placement: .topBarLeading) {
                weekToolbarMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingActivity = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(SMColor.textSecondary)
                }
                .accessibilityLabel("View week activity")
            }
            // Build 70 — Week has no top-bar sparkle (per spec); per-
            // day inline sparkles cover AI calls. Configurable
            // primary moved to the FAB.
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(SMColor.textSecondary)
                }
                .accessibilityLabel("Settings")
            }
        }
        .smithToolbar()
        // Build 62 — Fusion-styled meal action sheet. Replaces the
        // native confirmationDialog so the menu reads in the same
        // paper aesthetic as the rest of the redesign. Native sheet
        // chrome (drag indicator, swipe-down dismiss) preserved.
        .sheet(item: $selectedMealForAction) { meal in
            MealActionSheet(
                meal: meal,
                onViewRecipe: {
                    navigatingToRecipeID = meal.recipeId
                },
                onRate: {
                    feedbackMeal = meal
                },
                onEditName: {
                    renameText = meal.recipeName
                    renamingMeal = meal
                },
                onEditNotes: {
                    editingMeal = meal
                },
                onManageSides: {
                    sidesMeal = meal
                },
                onMove: {
                    movingMeal = meal
                },
                onLinkRecipe: {
                    linkRecipeMeal = meal
                },
                onCreateWithAI: {
                    aiCreateMeal = meal
                },
                onToggleApproval: {
                    Task { await toggleMealApproval(meal, approved: !meal.approved) }
                },
                onMarkEatingOut: {
                    markEatingOut(meal)
                },
                onSaveLeftovers: {
                    leftoverSourceMeal = meal
                },
                onRemove: {
                    removeMeal(meal)
                }
            )
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
            NavigationStack { GroceryView(dismissable: true) }
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
        .sheet(item: $leftoverSourceMeal) { meal in
            SaveLeftoversToFreezerSheet(meal: meal)
        }
        .sheet(item: $sidesMeal) { meal in
            if let week = displayedWeek {
                MealSidesSheet(weekID: week.weekId, mealID: meal.mealId)
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
        VStack(alignment: .leading, spacing: 0) {
            // Build 59 — Fusion paper-styled "the week" header.
            // Handwritten Caveat label with ember underline + the
            // weekly calorie pill (kept from build 58 — useful at-a-
            // glance signal) repositioned into the same row.
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: SMSpacing.sm) {
                    Text("the week")
                        .font(SMFont.handwritten(22, bold: true))
                        .foregroundStyle(SMColor.ink)
                    HandUnderline(color: SMColor.ember, width: 50)
                }

                Spacer()

                if let weekly = week.weeklyTotals, let goal = appState.profile?.dietaryGoal {
                    let weeklyTarget = goal.dailyCalories * 7
                    let pctOff = weeklyTarget > 0 ? Int(((weekly.calories - Double(weeklyTarget)) / Double(weeklyTarget)) * 100) : 0
                    let inRange = abs(pctOff) <= 10
                    HStack(spacing: SMSpacing.xs) {
                        Image(systemName: inRange ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.caption)
                        Text("\(Int(weekly.calories)) / \(weeklyTarget) cal")
                            .font(SMFont.caption.monospacedDigit())
                    }
                    .foregroundStyle(inRange ? SMColor.risoGreen : SMColor.ember)
                }
            }
            .padding(.top, SMSpacing.md)
            .padding(.bottom, SMSpacing.sm)

            ForEach(Array(days.enumerated()), id: \.element.date) { idx, day in
                daySection(week: week, date: day.date, dayName: day.dayName)
                if idx < days.count - 1 {
                    HandRule(color: SMColor.rule, height: 5, lineWidth: 0.8)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    /// Build 61 — true when a date is strictly before today's local
    /// calendar day. Uses YYYY-MM-DD string comparison for safe
    /// chronological sort across timezones.
    private func isPastDay(_ date: Date) -> Bool {
        DayKey.server(date) < DayKey.local(Date())
    }

    @ViewBuilder
    private func daySection(week: WeekSnapshot, date: Date, dayName: String) -> some View {
        let meals = mealsForDate(date, in: week)
        let isToday = DayKey.isToday(date)
        let totals = dayMacros(for: date, meals: meals, week: week)
        let showMacros = !totals.isEmpty && (appState.profile?.dietaryGoal != nil || totals.calories > 0)
        let dayNum = Calendar.current.component(.day, from: date)
        let dayKey = DayKey.server(date)
        let past = isPastDay(date)
        let expanded = expandedPastDays.contains(dayKey)
        let showSlots = !past || expanded

        // Build 61 — bigger Fusion day pillar. Today gets a 3pt ember
        // spine; past days collapse to the pillar + a summary line and
        // expand on tap. Today and future days always render slots.
        HStack(alignment: .top, spacing: SMSpacing.md) {
            // Ember spine on today (taller now to match bigger pillar)
            Rectangle()
                .fill(isToday ? SMColor.ember : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 4)

            // Build 66 — flipped sizes: italic-serif day name on top
            // (the big anchor), small handwritten date numeral below.
            VStack(spacing: 0) {
                Text(String(dayName.lowercased().prefix(3)))
                    .font(SMFont.serifDisplay(32))
                    .foregroundStyle(isToday ? SMColor.ember : (past ? SMColor.inkFaint : SMColor.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(dayNum)")
                    .font(SMFont.handwritten(15, bold: true))
                    .foregroundStyle(isToday ? SMColor.ember : SMColor.inkSoft)
            }
            .frame(width: 60)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: SMSpacing.sm) {
                    if isToday {
                        Text("today")
                            .font(SMFont.handwritten(14, bold: true))
                            .foregroundStyle(SMColor.ember)
                    } else if past {
                        // Past-day summary in the header line so a
                        // collapsed row still reads at a glance.
                        Text(pastDaySummary(meals: meals))
                            .font(SMFont.bodySerifItalic(13))
                            .foregroundStyle(SMColor.inkFaint)
                            .lineLimit(1)
                    }

                    Spacer()

                    if past {
                        // Expand/collapse chevron for past days.
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if expanded {
                                    expandedPastDays.remove(dayKey)
                                } else {
                                    expandedPastDays.insert(dayKey)
                                }
                            }
                        } label: {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SMColor.inkSoft)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded ? "Collapse \(dayName)" : "Expand \(dayName)")
                    } else {
                        Button {
                            publishFocus(date: date, dayName: dayName)
                            aiCoordinator.present()
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(SMColor.ember)
                                .padding(6)
                                .overlay(Circle().stroke(SMColor.ember.opacity(0.4), lineWidth: 0.8))
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
                }

                if showSlots {
                    renderSlots(for: date, dayName: dayName, meals: meals, style: .compact)

                    addSnackAffordance(for: date, dayName: dayName, meals: meals)

                    rebalanceBanner(for: date, dayName: dayName, totals: totals)
                }
            }
        }
        .padding(.vertical, SMSpacing.sm)
    }

    /// Build 61 — past-day collapsed-header summary. Reads as
    /// "3 meals · 2 done" / "1 meal" / "no meals planned".
    private func pastDaySummary(meals: [WeekMeal]) -> String {
        if meals.isEmpty { return "no meals planned" }
        let cooked = meals.filter { $0.approved }.count
        let total = meals.count
        let mealWord = total == 1 ? "meal" : "meals"
        if cooked == 0 { return "\(total) \(mealWord)" }
        if cooked == total { return "\(total) \(mealWord) · all done" }
        return "\(total) \(mealWord) · \(cooked) done"
    }

    @ViewBuilder
    private func addSnackAffordance(for date: Date, dayName: String, meals: [WeekMeal]) -> some View {
        // Build 59 — Fusion snack add. Caveat micro-label "+ snack"
        // in ember; very low visual weight so it doesn't compete
        // with the main meal slots.
        let hasSnack = meals.contains { $0.slot.lowercased() == "snack" || $0.slot.lowercased() == "snacks" }
        if !hasSnack {
            Button {
                quickAddSlot = (dayName: dayName, mealDate: date, slot: "snack")
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("snack")
                        .font(SMFont.handwritten(13))
                }
                .foregroundStyle(SMColor.ember)
                .padding(.horizontal, SMSpacing.sm)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add snack to \(dayName)")
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
        // Build 59 — Fusion empty slot. Paper tile with dashed rule
        // border, Caveat slot label, italic-serif "plan a meal"
        // placeholder, ember plus on the right.
        Button {
            quickAddSlot = (dayName: dayName, mealDate: mealDate, slot: slot)
        } label: {
            HStack(spacing: SMSpacing.md) {
                Text(slot.lowercased())
                    .font(SMFont.handwritten(14))
                    .foregroundStyle(SMColor.inkSoft)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 70, alignment: .leading)

                Text("plan a meal")
                    .font(SMFont.bodySerifItalic(14))
                    .foregroundStyle(SMColor.inkFaint)

                Spacer()

                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SMColor.ember)
            }
            .padding(.horizontal, SMSpacing.md)
            .padding(.vertical, SMSpacing.sm)
            .overlay(
                Rectangle()
                    .stroke(SMColor.rule, style: StrokeStyle(lineWidth: 0.6, dash: [3, 2]))
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

    /// Build 87 — small "plan" pill in the FuHero trailing slot that
    /// opens the PlanShoppingSheet. Replaces the now-disabled implicit
    /// "meal → grocery list" auto-population.
    @ViewBuilder
    private var planShoppingTrailing: some View {
        Button {
            showingPlanShopping = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cart.badge.plus")
                    .font(.caption)
                Text("plan")
                    .font(SMFont.handwritten(14, bold: true))
            }
            .foregroundStyle(SMColor.ember)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().stroke(SMColor.ember.opacity(0.4), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plan shopping for this week")
    }

    /// Build 86 — Savanne dogfood: horizontal swipe across the Fusion
    /// hero jumps a week. Left = next, right = previous. The 60pt
    /// horizontal threshold + 2:1 horizontal-vs-vertical ratio keep
    /// vertical scroll dominant and require an intentional drag.
    private var weekHeroSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 2 else { return }
                if dx < 0 {
                    navigateToNextWeek()
                } else {
                    navigateToPreviousWeek()
                }
            }
    }

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

    // MARK: - Build 59: Fusion Week IA helpers

    /// Build 59: toolbar menu that absorbs the week picker, jump-to-
    /// week list, "snap to current week", approve-all, and in-season
    /// strip — all controls that used to live inline in the scroll.
    /// Replaces `weekPicker` / `approveAllBar` / `InSeasonStrip` as
    /// scroll-surface elements.
    @ViewBuilder
    private var weekToolbarMenu: some View {
        Menu {
            Section {
                Button {
                    navigateToPreviousWeek()
                } label: {
                    Label("Previous week", systemImage: "chevron.left")
                }
                .disabled(navigationAnchor == nil)

                Button {
                    navigateToNextWeek()
                } label: {
                    Label("Next week", systemImage: "chevron.right")
                }
                .disabled(navigationAnchor == nil)

                if !isViewingCurrentWeek {
                    Button {
                        snapToCurrentWeek()
                    } label: {
                        Label("Jump to this week", systemImage: "arrow.uturn.backward")
                    }
                }
            }

            if let week = displayedWeek {
                Section {
                    let needsApproval = week.meals.contains { !$0.approved }
                    Button {
                        Task { await approveAllMeals(week) }
                    } label: {
                        Label(needsApproval ? "Approve all meals" : "All meals approved", systemImage: "checkmark.seal")
                    }
                    .disabled(!needsApproval || isApprovingAll)
                }
            }

            if !availableWeeks.isEmpty {
                Section("Jump to week") {
                    ForEach(availableWeeks.prefix(8)) { week in
                        Button {
                            selectWeek(week)
                        } label: {
                            Label(weekPillLabel(for: week.weekStart), systemImage: isWeekSelected(week) ? "checkmark" : "")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                FuWordmark(size: 16)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SMColor.inkSoft)
            }
        }
    }

    /// Build 59: sparse "the week" roster — one row per day showing
    /// the dinner (or first non-snack meal) with a Caveat sub-line
    /// of sides/notes and either ✓ done or cook minutes on the right.
    /// Today gets an ember spine on the left; rows separated by hand
    /// rules. Tap a row to open the existing meal action sheet for
    /// that meal (or to quick-add a meal if the slot is empty).
    @ViewBuilder
    private func weekRosterSection(_ week: WeekSnapshot) -> some View {
        let days = weekDays(of: week)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SMSpacing.sm) {
                Text("the week")
                    .font(SMFont.handwritten(22, bold: true))
                    .foregroundStyle(SMColor.ink)
                HandUnderline(color: SMColor.ember, width: 50)
            }
            .padding(.top, SMSpacing.lg)
            .padding(.bottom, SMSpacing.sm)

            ForEach(Array(days.enumerated()), id: \.element.date) { idx, day in
                weekRosterRow(week: week, date: day.date, dayName: day.dayName)
                if idx < days.count - 1 {
                    HandRule(color: SMColor.rule, height: 5, lineWidth: 0.8)
                }
            }
        }
    }

    @ViewBuilder
    private func weekRosterRow(week: WeekSnapshot, date: Date, dayName: String) -> some View {
        let meals = mealsForDate(date, in: week)
        let primary = featuredMeal(in: meals)
        let isToday = DayKey.isToday(date)
        let dayNum = Calendar.current.component(.day, from: date)

        Button {
            if let primary {
                selectedMealForAction = primary
            } else {
                quickAddSlot = (dayName: dayName, mealDate: date, slot: defaultSlotName())
            }
        } label: {
            HStack(alignment: .center, spacing: SMSpacing.md) {
                // Ember spine on today
                Rectangle()
                    .fill(isToday ? SMColor.ember : Color.clear)
                    .frame(width: 2)
                    .padding(.vertical, 2)

                // Day pillar — handwritten name + italic-serif numeral
                VStack(spacing: 0) {
                    Text(dayName.lowercased().prefix(3).description)
                        .font(SMFont.handwritten(13))
                        .foregroundStyle(isToday ? SMColor.ember : SMColor.inkSoft)
                    Text("\(dayNum)")
                        .font(SMFont.serifDisplay(22))
                        .foregroundStyle(isToday ? SMColor.ember : SMColor.ink)
                }
                .frame(width: 36)

                // Meal text
                VStack(alignment: .leading, spacing: 2) {
                    if let primary {
                        Text(primary.recipeName)
                            .font(SMFont.serifTitle(17))
                            .foregroundStyle(SMColor.ink)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                        let sub = rosterSubline(for: primary)
                        if !sub.isEmpty {
                            Text(sub)
                                .font(SMFont.handwritten(13))
                                .foregroundStyle(SMColor.inkSoft)
                                .lineLimit(1)
                        }
                    } else {
                        Text("plan a meal")
                            .font(SMFont.bodySerifItalic(15))
                            .foregroundStyle(SMColor.inkFaint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Trailing — done or cook minutes
                Group {
                    if let primary, primary.approved {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("done")
                                .font(SMFont.handwritten(13))
                        }
                        .foregroundStyle(SMColor.ember)
                    } else if let primary, let mins = rosterCookMinutes(for: primary), mins > 0 {
                        Text("\(mins)m")
                            .font(SMFont.handwritten(14))
                            .foregroundStyle(SMColor.inkSoft)
                    } else if primary == nil {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SMColor.ember)
                    } else {
                        Color.clear.frame(width: 0)
                    }
                }
            }
            .padding(.vertical, SMSpacing.sm)
        }
        .buttonStyle(.plain)
    }

    /// Pick the meal to feature on a day's roster row. Prefer dinner;
    /// fall back to the first non-snack slot; fall back to anything.
    private func featuredMeal(in meals: [WeekMeal]) -> WeekMeal? {
        if let dinner = meals.first(where: { $0.slot.lowercased() == "dinner" }) {
            return dinner
        }
        if let nonSnack = meals.first(where: { $0.slot.lowercased() != "snack" && $0.slot.lowercased() != "snacks" }) {
            return nonSnack
        }
        return meals.first
    }

    /// Build the Caveat sub-line for a roster row. Prefers sides
    /// (joined by " · "), falls back to the first meaningful chunk
    /// of notes, falls back to empty.
    private func rosterSubline(for meal: WeekMeal) -> String {
        if !meal.sides.isEmpty {
            return meal.sides.map { $0.name.lowercased() }.joined(separator: " · ")
        }
        if !meal.notes.isEmpty {
            let trimmed = meal.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstLine = trimmed.split(separator: "\n").first {
                return String(firstLine).lowercased()
            }
        }
        return ""
    }

    /// Total cooking time (prep + cook) for the linked recipe, if any.
    /// Returns nil when the recipe isn't on hand or both fields are 0.
    private func rosterCookMinutes(for meal: WeekMeal) -> Int? {
        guard let id = meal.recipeId,
              let recipe = appState.recipes.first(where: { $0.recipeId == id }) else {
            return nil
        }
        let total = (recipe.prepMinutes ?? 0) + (recipe.cookMinutes ?? 0)
        return total > 0 ? total : nil
    }

    /// Default slot used when tapping an empty roster row. Picks
    /// "dinner" if the user hasn't customized default_slots, else
    /// the first non-snack configured slot.
    private func defaultSlotName() -> String {
        configuredSlots.first { $0.lowercased() != "snack" && $0.lowercased() != "snacks" } ?? "dinner"
    }

    /// Build 59: bulk-approve every unapproved meal on the displayed
    /// week. Surfaced via the toolbar Menu (replaces the old inline
    /// approveAllBar). Sets `isApprovingAll` so the menu disables
    /// while the request is in flight. Reuses the existing
    /// per-meal toggleMealApproval helper instead of duplicating
    /// the MealUpdateRequest serialization.
    private func approveAllMeals(_ week: WeekSnapshot) async {
        let unapproved = week.meals.filter { !$0.approved }
        guard !unapproved.isEmpty else { return }
        isApprovingAll = true
        defer { isApprovingAll = false }
        for meal in unapproved {
            await toggleMealApproval(meal, approved: true)
        }
    }

    /// Build 58: hero header eyebrow. Reads "WEEK 10 · MAR 4" or
    /// "WEEK OF MAR 4" depending on data availability.
    private var weekHeroEyebrow: String {
        if let week = displayedWeek {
            let weekNumber = Self.weekCalendar.component(.weekOfYear, from: week.weekStart)
            return "week \(weekNumber) · \(Self.weekDateFormatter.string(from: week.weekStart))"
        }
        if let start = displayedWeekStart {
            return "week of \(Self.weekDateFormatter.string(from: start))"
        }
        return "no week yet"
    }

    /// Build 81 — hero title is "this week" only when actually viewing
    /// the current ISO week. Future weeks read "next week", "in 2 weeks",
    /// or "the week of MAR 4". Past weeks read "last week" / etc.
    /// Savanne reported future weeks were stuck saying "this week".
    private var weekHeroTitle: String {
        guard let start = displayedWeekStart ?? appState.currentWeek?.weekStart else {
            return "this week"
        }
        let cal = Self.weekCalendar
        let today = cal.startOfDay(for: Date())
        let currentWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let displayedWeekDay = cal.startOfDay(for: start)
        let weeks = cal.dateComponents([.weekOfYear], from: currentWeekStart, to: displayedWeekDay).weekOfYear ?? 0
        switch weeks {
        case 0: return "this week"
        case 1: return "next week"
        case -1: return "last week"
        case 2...: return "in \(weeks) weeks"
        case ...(-2): return "\(-weeks) weeks ago"
        default: return "this week"
        }
    }

    private var weekHeroEmberAccent: String? {
        // Only highlight the dot in "this week" — keeps the look quiet
        // for arbitrary date labels.
        nil
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
