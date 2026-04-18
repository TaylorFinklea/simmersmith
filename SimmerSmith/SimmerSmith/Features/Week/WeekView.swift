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

    // MARK: - Day key helpers (match server's calendar-day semantics)
    //
    // Server sends `meal_date` / `week_start` as "YYYY-MM-DD" strings. The iOS
    // JSON decoder parses those as Date at UTC midnight, so interpreting them
    // in the user's local timezone shifts the wall-clock date by several hours
    // in either direction. To stay consistent with what the server meant, we
    // compare calendar days as "YYYY-MM-DD" strings formatted in UTC for
    // server-supplied dates, and in local time for "now".

    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let utcWeekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEEE"
        return f
    }()

    private static let utcShortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "MMM d"
        return f
    }()

    private static var utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private func dayKey(_ date: Date) -> String {
        Self.utcDayFormatter.string(from: date)
    }

    private var todayKey: String {
        Self.localDayFormatter.string(from: Date())
    }

    private func isTodayDate(_ date: Date) -> Bool {
        dayKey(date) == todayKey
    }

    private func mealsForDate(_ date: Date, in week: WeekSnapshot) -> [WeekMeal] {
        let key = dayKey(date)
        return week.meals
            .filter { dayKey($0.mealDate) == key }
            .sorted { slotOrder($0.slot) < slotOrder($1.slot) }
    }

    // MARK: - Today Hero (always at the top)

    @ViewBuilder
    private func todayHero(_ week: WeekSnapshot) -> some View {
        let today = Date()
        let weekContainsToday = (0..<7).contains { offset in
            guard let d = Self.utcCalendar.date(byAdding: .day, value: offset, to: week.weekStart) else { return false }
            return isTodayDate(d)
        }

        if weekContainsToday {
            let todayDate = (0..<7).compactMap {
                Self.utcCalendar.date(byAdding: .day, value: $0, to: week.weekStart)
            }.first(where: { isTodayDate($0) }) ?? today

            let meals = mealsForDate(todayDate, in: week)
            let dayName = meals.first?.dayName ?? Self.utcWeekdayFormatter.string(from: todayDate)

            VStack(alignment: .leading, spacing: SMSpacing.md) {
                VStack(alignment: .leading, spacing: SMSpacing.xs) {
                    Text("Today")
                        .font(SMFont.display)
                        .foregroundStyle(SMColor.textPrimary)

                    Text(Self.utcShortDateFormatter.string(from: todayDate) + " · " + dayName)
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textSecondary)
                }

                renderSlots(for: todayDate, dayName: dayName, meals: meals, style: .hero)
            }
            .padding(.top, SMSpacing.sm)
        }
    }

    // MARK: - Days Grid (all 7 days of the week)

    private func weekDays(of week: WeekSnapshot) -> [(date: Date, dayName: String)] {
        let cal = Self.utcCalendar
        let start = cal.startOfDay(for: week.weekStart)
        return (0..<7).map { offset in
            let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
            let name = Self.utcWeekdayFormatter.string(from: date)
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
            Text("This Week")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
                .padding(.top, SMSpacing.md)

            ForEach(days, id: \.date) { day in
                daySection(week: week, date: day.date, dayName: day.dayName)
            }
        }
    }

    @ViewBuilder
    private func daySection(week: WeekSnapshot, date: Date, dayName: String) -> some View {
        let meals = mealsForDate(date, in: week)
        let isToday = isTodayDate(date)

        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: SMSpacing.sm) {
                Text(dayName)
                    .font(SMFont.subheadline)
                    .foregroundStyle(isToday ? SMColor.textPrimary : SMColor.primary)

                Text(Self.utcShortDateFormatter.string(from: date))
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
            }
            .padding(.top, SMSpacing.xs)

            renderSlots(for: date, dayName: dayName, meals: meals, style: .compact)
        }
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
}
