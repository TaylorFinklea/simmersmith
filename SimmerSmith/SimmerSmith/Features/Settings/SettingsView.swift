import EventKit
import SwiftUI
import UIKit
import SimmerSmithKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var preferenceEditor: IngredientPreferenceEditorContext?
    @State private var guestEditor: Guest? = nil
    @State private var isCreatingGuest: Bool = false
    @State private var isBackfillingImages = false
    @State private var imageBackfillToast: String?

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                TextField("Server URL", text: $appState.serverURLDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                SecureField("Bearer token", text: $appState.authTokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save Connection") {
                    Task { await appState.saveConnectionDetails() }
                }
                .buttonStyle(.borderedProminent)
            } header: {
                SmithSectionHeader("server")
            }

            Section {
                Text(appState.syncStatusText)
                    .foregroundStyle(SMColor.textSecondary)

                if let updatedAt = appState.currentWeek?.updatedAt {
                    LabeledContent("Current week") {
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }
                if let updatedAt = appState.profile?.updatedAt {
                    LabeledContent("Profile") {
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }

                Button("Refresh Now") {
                    Task { await appState.refreshAll() }
                }
            } header: {
                SmithSectionHeader("sync")
            }

            HouseholdSection()

            GrocerySection()

            TopBarSection()

            ForgeSection()

            Section {
                if let capabilities = appState.aiCapabilities {
                    if let target = capabilities.defaultTarget {
                        LabeledContent("Default route") {
                            Text(target.providerKind == "mcp" ? (target.mcpServerName ?? "MCP") : (target.providerName ?? "Direct"))
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    } else {
                        Text(appState.assistantExecutionStatusText)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    LabeledContent("Preferred mode") {
                        Text(capabilities.preferredMode.capitalized)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    LabeledContent("User override") {
                        Text(capabilities.userOverrideConfigured ? "Configured" : "Not configured")
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    ForEach(capabilities.availableProviders) { provider in
                        LabeledContent(provider.label) {
                            Text(provider.available ? provider.source.replacingOccurrences(of: "_", with: " ").capitalized : "Unavailable")
                                .foregroundStyle(provider.available ? SMColor.textSecondary : SMColor.textTertiary)
                        }
                    }
                } else {
                    Text(appState.assistantExecutionStatusText)
                        .foregroundStyle(SMColor.textSecondary)
                }

                Picker("Preferred mode", selection: $appState.aiProviderModeDraft) {
                    Text("Auto").tag("auto")
                    Text("MCP").tag("mcp")
                    Text("Direct").tag("direct")
                }

                Picker("Direct provider", selection: $appState.aiDirectProviderDraft) {
                    Text("None").tag("")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                }

                if !appState.aiDirectProviderDraft.isEmpty {
                    if !appState.selectedDirectProviderModels.isEmpty {
                        Picker("Model", selection: $appState.selectedDirectProviderModelDraft) {
                            ForEach(appState.selectedDirectProviderModels) { model in
                                Text(model.displayName).tag(model.modelId)
                            }
                        }
                    } else if let modelError = appState.selectedDirectProviderModelError {
                        Text(modelError)
                            .font(.footnote)
                            .foregroundStyle(SMColor.textSecondary)
                    } else {
                        Text("Discovering available models for the selected provider…")
                            .font(.footnote)
                            .foregroundStyle(SMColor.textSecondary)
                    }

                    Button("Refresh Models") {
                        Task { await appState.refreshAIModels(for: appState.aiDirectProviderDraft) }
                    }
                }

                SecureField(
                    appState.aiDirectProviderDraft.isEmpty
                        ? "New direct-provider API key"
                        : "New \(appState.aiDirectProviderDraft.capitalized) API key",
                    text: $appState.aiDirectAPIKeyDraft
                )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text(apiKeyStatusText)
                    .font(.footnote)
                    .foregroundStyle(SMColor.textSecondary)

                Button("Save AI Settings") {
                    Task { await appState.saveAISettings() }
                }

                Button("Clear Stored API Key", role: .destructive) {
                    Task { await appState.saveAISettings(clearStoredAPIKey: true) }
                }
                .disabled(!appState.aiDirectAPIKeyConfigured)

                NavigationLink {
                    HouseholdAliasesView()
                } label: {
                    HStack {
                        Label("Custom terms", systemImage: "textformat.abc")
                        Spacer()
                        if !appState.householdAliases.isEmpty {
                            Text("\(appState.householdAliases.count)")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                }

                // M27 — unit-system localization. Constrains AI-
                // generated and AI-found recipes to one unit system.
                @Bindable var unitsBindable = appState
                Picker("Recipe units", selection: $unitsBindable.unitSystemDraft) {
                    Text("US (cups, tbsp, °F)").tag("us")
                    Text("Metric (g, ml, °C)").tag("metric")
                }
                .onChange(of: appState.unitSystemDraft) { _, newValue in
                    Task { await appState.saveUnitSystem(newValue) }
                }
            } header: {
                SmithSectionHeader("ai")
            }

            Section {
                Text("New recipes get an AI-generated header image automatically. Pick the model that draws them — you can switch any time.")
                    .font(.footnote)
                    .foregroundStyle(SMColor.textSecondary)

                @Bindable var imageBindable = appState
                Picker("Image style", selection: $imageBindable.imageProviderDraft) {
                    Text("OpenAI").tag("openai")
                    Text("Gemini").tag("gemini")
                }
                .onChange(of: appState.imageProviderDraft) { _, newValue in
                    Task { await appState.saveImageProvider(newValue) }
                }

                Text("Affects new recipes, regenerations, and the backfill below. Existing images stay unchanged until you regenerate them.")
                    .font(.footnote)
                    .foregroundStyle(SMColor.textSecondary)

                Button {
                    Task { await runImageBackfill() }
                } label: {
                    HStack {
                        if isBackfillingImages {
                            ProgressView().controlSize(.small)
                        }
                        Text(isBackfillingImages ? "Generating…" : "Generate missing images")
                    }
                }
                .disabled(isBackfillingImages)

                if let imageBackfillToast {
                    Text(imageBackfillToast)
                        .font(.footnote)
                        .foregroundStyle(SMColor.textSecondary)
                }
            } header: {
                SmithSectionHeader("recipe images")
            }

            NotificationsSection()

            Section {
                LabeledContent("Recipe templates") {
                    Text("\(appState.recipeTemplateCount)")
                        .foregroundStyle(SMColor.textSecondary)
                }
                if let defaultTemplate = appState.recipeMetadata?.templates.first(where: { $0.templateId == appState.recipeMetadata?.defaultTemplateId }) {
                    LabeledContent("Default template") {
                        Text(defaultTemplate.name)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                } else {
                    Text("Template library syncs with recipe metadata.")
                        .foregroundStyle(SMColor.textSecondary)
                }
            } header: {
                SmithSectionHeader("templates")
            }

            Section {
                NavigationLink {
                    StoreSelectionView()
                } label: {
                    HStack {
                        Label("Preferred Store", systemImage: "cart")
                        Spacer()
                        if let storeName = appState.profile?.settings["kroger_store_name"], !storeName.isEmpty {
                            Text(storeName)
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                                .lineLimit(1)
                        } else {
                            Text("Not set")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                }
            } header: {
                SmithSectionHeader("grocery")
            }

            Section {
                @Bindable var bindable = appState
                TextField("Region (e.g., Kansas, USA)", text: $bindable.userRegionDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button {
                    Task { await appState.saveUserRegion(appState.userRegionDraft) }
                } label: {
                    Text("Save region")
                }
                .disabled(
                    appState.userRegionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        == (appState.profile?.settings["user_region"] ?? "")
                )
            } header: {
                SmithSectionHeader("location")
            } footer: {
                Text("Used for the in-season produce snapshot on the Week tab. Free-form — try \"Kansas, USA\" or \"Northern California\".")
                    .font(.footnote)
            }

            Section {
                NavigationLink {
                    DietaryGoalView()
                } label: {
                    HStack {
                        Label("Dietary Goal", systemImage: "target")
                        Spacer()
                        if let goal = appState.profile?.dietaryGoal {
                            Text("\(goal.dailyCalories) cal · \(goal.goalType.rawValue.capitalized)")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                                .lineLimit(1)
                        } else {
                            Text("Not set")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                }
            } header: {
                SmithSectionHeader("nutrition")
            }

            Section {
                if appState.isTrialPro {
                    VStack(alignment: .leading, spacing: SMSpacing.xs) {
                        HStack {
                            Label("SimmerSmith Pro", systemImage: "sparkles")
                                .foregroundStyle(SMColor.aiPurple)
                            Spacer()
                            Text("Beta promo")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SMColor.aiPurple)
                                .padding(.horizontal, SMSpacing.xs)
                                .padding(.vertical, 2)
                                .background(SMColor.aiPurple.opacity(0.15), in: Capsule())
                        }
                        Text("All Pro features are unlocked during SimmerSmith's beta. No payment required — this will convert to a paid tier before public launch.")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                } else if appState.isPro {
                    HStack {
                        Label("SimmerSmith Pro", systemImage: "sparkles")
                            .foregroundStyle(SMColor.aiPurple)
                        Spacer()
                        Text("Active")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.success)
                    }
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        Link("Manage in App Store", destination: url)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.primary)
                    }
                } else {
                    let aiUsage = appState.usage(for: "ai_generate")
                    let priceUsage = appState.usage(for: "pricing_fetch")
                    VStack(alignment: .leading, spacing: SMSpacing.xs) {
                        HStack {
                            Label("Free tier", systemImage: "circle.dotted")
                            Spacer()
                        }
                        if let aiUsage {
                            Text("AI generations: \(aiUsage.used) of \(aiUsage.limit) this month")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                        if let priceUsage {
                            Text("Kroger fetches: \(priceUsage.used) of \(priceUsage.limit) this month")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                    Button {
                        appState.presentPaywall(.manualUpgrade)
                    } label: {
                        HStack {
                            Spacer()
                            Label("Upgrade to Pro", systemImage: "sparkles")
                                .font(SMFont.subheadline)
                            Spacer()
                        }
                    }
                    .foregroundStyle(SMColor.aiPurple)
                }
            } header: {
                SmithSectionHeader("subscription")
            }

            Section {
                if appState.ingredientPreferences.isEmpty {
                    Text("Set household defaults like a preferred biscuit brand or whether to pick the cheapest option.")
                        .foregroundStyle(SMColor.textSecondary)
                } else {
                    ForEach(appState.ingredientPreferences) { preference in
                        Button {
                            preferenceEditor = IngredientPreferenceEditorContext(preference: preference)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(preference.baseIngredientName)
                                        .foregroundStyle(SMColor.textPrimary)
                                    if preference.rank > 1 && !preference.isAvoidance {
                                        // Primary rows aren't labelled (it's the
                                        // implicit default); secondary/tertiary
                                        // get a chip so the list reads clearly
                                        // when a base has multiple ranks.
                                        Text(rankLabel(preference.rank))
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(SMColor.aiPurple.opacity(0.15), in: Capsule())
                                            .foregroundStyle(SMColor.aiPurple)
                                    }
                                    if !preference.active {
                                        Text("Inactive")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(.thinMaterial, in: Capsule())
                                            .foregroundStyle(SMColor.textSecondary)
                                    }
                                    Spacer()
                                    preferencePill(for: preference.choiceMode)
                                }
                                if preference.isAvoidance {
                                    // Brand / variation don't apply when the
                                    // user just wants to skip the ingredient.
                                    Text(preference.choiceMode == "allergy"
                                        ? "Never plan meals with this"
                                        : "Skip in week planner")
                                        .font(.footnote)
                                        .foregroundStyle(SMColor.textSecondary)
                                } else if let variationName = preference.preferredVariationName, !variationName.isEmpty {
                                    Text(variationName)
                                        .font(.footnote)
                                        .foregroundStyle(SMColor.textSecondary)
                                } else if !preference.preferredBrand.isEmpty {
                                    Text(preference.preferredBrand)
                                        .font(.footnote)
                                        .foregroundStyle(SMColor.textSecondary)
                                } else {
                                    Text("Generic ingredient preference")
                                        .font(.footnote)
                                        .foregroundStyle(SMColor.textTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    preferenceEditor = IngredientPreferenceEditorContext()
                } label: {
                    Label("Add Ingredient Preference", systemImage: "plus.circle")
                }
            } header: {
                SmithSectionHeader("ingredient preferences")
            }

            Section {
                Text("Manage canonical ingredients, product variations, nutrition, and household preferences from one dedicated catalog area.")
                    .foregroundStyle(SMColor.textSecondary)

                NavigationLink {
                    IngredientsView()
                } label: {
                    Label("Manage Ingredient Catalog", systemImage: "square.stack.3d.up")
                }
            }

            Section {
                if appState.guests.isEmpty {
                    Text("Add people you regularly host. Save their age group + any allergies so event menu generation just works.")
                        .foregroundStyle(SMColor.textSecondary)
                } else {
                    ForEach(appState.guests) { guest in
                        Button {
                            guestEditor = guest
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: SMSpacing.xs) {
                                        Text(guest.name)
                                            .foregroundStyle(SMColor.textPrimary)
                                        if !guest.active {
                                            Text("Inactive")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(.thinMaterial, in: Capsule())
                                                .foregroundStyle(SMColor.textSecondary)
                                        }
                                    }
                                    if guest.ageGroup != "adult" {
                                        Text(guest.ageGroup.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(SMColor.primary)
                                    }
                                    if !guest.allergies.isEmpty {
                                        Text("⚠︎ \(guest.allergies)")
                                            .font(.footnote)
                                            .foregroundStyle(.red)
                                    }
                                    if !guest.dietaryNotes.isEmpty {
                                        Text(guest.dietaryNotes)
                                            .font(.footnote)
                                            .foregroundStyle(SMColor.textSecondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    isCreatingGuest = true
                } label: {
                    Label("Add guest", systemImage: "person.badge.plus")
                }
            } header: {
                SmithSectionHeader("guests")
            } footer: {
                Text("Your reusable guest list for the Events tab. Age group + allergies shape menu generation.")
            }

            Section {
                Button("Enable Meal Reminders") {
                    Task {
                        let granted = await NotificationManager.shared.requestPermission()
                        if granted, let week = appState.currentWeek {
                            NotificationManager.shared.scheduleMealReminders(for: week.meals)
                            NotificationManager.shared.scheduleGroceryReminder(itemCount: week.groceryItems.count)
                        }
                    }
                }

                Button("Turn Off Reminders") {
                    NotificationManager.shared.cancelAllReminders()
                }
                .foregroundStyle(SMColor.textSecondary)
            } header: {
                SmithSectionHeader("notifications")
            }

            Section {
                Button("Clear Local Cache", role: .destructive) {
                    appState.clearLocalCache()
                }

                Button("Reset Connection", role: .destructive) {
                    appState.resetConnection()
                }
            } header: {
                SmithSectionHeader("data")
            }

            Section {
                Button(role: .destructive) {
                    appState.resetConnection()
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Out")
                            .font(SMFont.subheadline)
                        Spacer()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.aiDirectProviderDraft) {
            await appState.refreshAIModels(for: appState.aiDirectProviderDraft)
        }
        .task {
            if appState.ingredientPreferences.isEmpty {
                await appState.refreshIngredientPreferences()
            }
        }
        .sheet(item: $preferenceEditor) { context in
            IngredientPreferenceEditorSheet(context: context)
        }
        .sheet(item: $guestEditor) { guest in
            GuestEditorSheet(guest: guest)
        }
        .sheet(isPresented: $isCreatingGuest) {
            GuestEditorSheet(guest: nil)
        }
        .task {
            if appState.guests.isEmpty {
                await appState.refreshGuests()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                FuWordmark(size: 18)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(SMColor.ember)
            }
        }
        .smithToolbar()
    }

    private var apiKeyStatusText: String {
        if appState.aiDirectProviderDraft.isEmpty {
            return "Select a direct provider to save or clear that provider's server-side API key."
        }
        if appState.aiDirectAPIKeyConfigured {
            return "A \(appState.aiDirectProviderDraft.capitalized) API key is stored on the server. It cannot be read back in the app."
        }
        return "No \(appState.aiDirectProviderDraft.capitalized) API key is currently stored on the server."
    }

    private func runImageBackfill() async {
        isBackfillingImages = true
        defer { isBackfillingImages = false }
        do {
            let result = try await appState.backfillRecipeImages()
            imageBackfillToast = "Generated \(result.generated) image\(result.generated == 1 ? "" : "s"). Skipped \(result.skipped), failed \(result.failed)."
        } catch {
            imageBackfillToast = "Backfill failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Top bar (Build 68)

/// One picker per tab. The user picks which action the per-page
/// "primary" slot in the top bar runs. Defaults match the page's
/// natural primary; sparkle is always available across pages so the
/// rightmost top-bar slot can be set to AI even when the page has
/// other natural actions.
private struct TopBarSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            ForEach(TopBarPage.allCases) { page in
                Picker(
                    page.displayLabel,
                    selection: Binding(
                        get: { appState.topBarPrimary(for: page) },
                        set: { appState.setTopBarPrimary($0, for: page) }
                    )
                ) {
                    ForEach(page.availableActions, id: \.self) { action in
                        Label(action.settingsLabel, systemImage: action.systemImage)
                            .tag(action)
                    }
                }
            }
        } header: {
            Text("Top bar")
        } footer: {
            Text("Each tab's top-bar primary action. ✨ Ask the Smith always sits on the far right of every tab except Week.")
        }
    }
}

// MARK: - Forge (Build 86)

/// Per-device Forge-page preferences. Backed by `@AppStorage` so they
/// stick across launches without a server round-trip. The
/// `simmersmith.forge.*` UserDefaults keys are the source of truth —
/// `RecipesView` reads them directly via its own `@AppStorage` so the
/// toggle takes effect without a state hop through AppState.
private struct ForgeSection: View {
    @AppStorage("simmersmith.forge.showRecentlyAdded") private var showRecentlyAdded = true

    var body: some View {
        Section {
            Toggle("Show Recently Added", isOn: $showRecentlyAdded)
        } header: {
            SmithSectionHeader("forge")
        } footer: {
            Text("When off, the Forge tab hides the Recently Added rail. The list view still shows all your recipes below.")
                .font(.footnote)
        }
    }
}

// MARK: - Notifications Section (M18)

private struct NotificationsSection: View {
    @Environment(AppState.self) private var appState

    // Local date state mirrors the profile string. Initialised lazily.
    @State private var tonightsMealDate: Date = NotificationsSection.dateFromTimeString("17:00")
    @State private var saturdayPlanDate: Date = NotificationsSection.dateFromTimeString("18:00")
    @State private var didInitDates = false

    var body: some View {
        Section {
            if appState.pushAuthorizationDenied {
                deniedBanner
            }

            Toggle("Tonight's meal", isOn: Binding(
                get: { appState.pushTonightsMealEnabled },
                set: { newValue in
                    Task { await appState.savePushPreference("push_tonights_meal", enabled: newValue) }
                }
            ))

            if appState.pushTonightsMealEnabled {
                DatePicker("Delivery time", selection: $tonightsMealDate, displayedComponents: .hourAndMinute)
                    .onChange(of: tonightsMealDate) { _, newDate in
                        Task { await appState.savePushTime("push_tonights_meal_time", date: newDate) }
                    }
            }

            Toggle("Saturday plan reminder", isOn: Binding(
                get: { appState.pushSaturdayPlanEnabled },
                set: { newValue in
                    Task { await appState.savePushPreference("push_saturday_plan", enabled: newValue) }
                }
            ))

            if appState.pushSaturdayPlanEnabled {
                DatePicker("Delivery time", selection: $saturdayPlanDate, displayedComponents: .hourAndMinute)
                    .onChange(of: saturdayPlanDate) { _, newDate in
                        Task { await appState.savePushTime("push_saturday_plan_time", date: newDate) }
                    }
            }

            Toggle("AI-finished thinking", isOn: Binding(
                get: { appState.pushAssistantDoneEnabled },
                set: { newValue in
                    Task { await appState.savePushPreference("push_assistant_done", enabled: newValue) }
                }
            ))
        } header: {
            Text("Notifications")
        } footer: {
            Text("On by default — toggle off to silence. We send push only at the times you set. Quiet hours: never between 22:00–07:00 local. The AI-finished push only fires when the app is backgrounded mid-turn.")
                .font(.footnote)
        }
        .onAppear {
            guard !didInitDates else { return }
            didInitDates = true
            tonightsMealDate = NotificationsSection.dateFromTimeString(appState.pushTonightsMealTime)
            saturdayPlanDate = NotificationsSection.dateFromTimeString(appState.pushSaturdayPlanTime)
            Task { await appState.refreshPushAuthorizationStatus() }
        }
    }

    /// Shown when iOS has the user's notifications-denied state on record.
    /// `requestAuthorization` cannot re-prompt after a denial — only the
    /// system Settings deep-link recovers.
    @ViewBuilder
    private var deniedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Notifications are off in iOS Settings", systemImage: "bell.slash")
                .font(.subheadline.weight(.semibold))
            Text("Open iOS Settings → Notifications → SimmerSmith and turn on Allow Notifications. Toggling the switches here can't override an iOS-level denial.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open iOS Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    /// Parse "HH:mm" into a `Date` using today's calendar (only HH:mm components matter for DatePicker).
    static func dateFromTimeString(_ s: String) -> Date {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return Date() }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = parts[0]
        comps.minute = parts[1]
        return Calendar.current.date(from: comps) ?? Date()
    }
}

struct IngredientPreferenceEditorContext: Identifiable {
    let id = UUID()
    let preference: IngredientPreference?
    let seedBaseIngredientID: String?
    let seedBaseIngredientName: String?
    let seedPreferredVariationID: String?

    init(
        preference: IngredientPreference? = nil,
        seedBaseIngredientID: String? = nil,
        seedBaseIngredientName: String? = nil,
        seedPreferredVariationID: String? = nil
    ) {
        self.preference = preference
        self.seedBaseIngredientID = seedBaseIngredientID
        self.seedBaseIngredientName = seedBaseIngredientName
        self.seedPreferredVariationID = seedPreferredVariationID
    }
}

struct IngredientPreferenceEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: IngredientPreferenceEditorContext

    @State private var searchText: String
    @State private var searchResults: [BaseIngredient] = []
    @State private var selectedBaseIngredient: BaseIngredient?
    @State private var variations: [IngredientVariation] = []
    @State private var preferredVariationID: String
    @State private var preferredBrand: String
    @State private var choiceMode: String
    @State private var notes: String
    @State private var isActive: Bool
    @State private var rank: Int
    @State private var isSearching = false
    @State private var isLoadingVariations = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didLoad = false

    init(context: IngredientPreferenceEditorContext) {
        self.context = context
        _searchText = State(initialValue: context.preference?.baseIngredientName ?? context.seedBaseIngredientName ?? "")
        _preferredVariationID = State(initialValue: context.preference?.preferredVariationId ?? context.seedPreferredVariationID ?? "")
        _preferredBrand = State(initialValue: context.preference?.preferredBrand ?? "")
        _choiceMode = State(initialValue: context.preference?.choiceMode ?? "preferred")
        _notes = State(initialValue: context.preference?.notes ?? "")
        _isActive = State(initialValue: context.preference?.active ?? true)
        _rank = State(initialValue: context.preference?.rank ?? 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Canonical Ingredient") {
                    TextField("Search ingredients", text: $searchText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit {
                            Task { await searchIngredients() }
                        }

                    Button {
                        Task { await searchIngredients() }
                    } label: {
                        HStack {
                            if isSearching {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Search Catalog")
                        }
                    }
                    .disabled(isSearching)

                    if let selectedBaseIngredient {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedBaseIngredient.name)
                                .font(.headline)
                            if !selectedBaseIngredient.category.isEmpty {
                                Text(selectedBaseIngredient.category)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !searchResults.isEmpty {
                        ForEach(searchResults) { ingredient in
                            Button {
                                Task { await selectBaseIngredient(ingredient) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ingredient.name)
                                            .foregroundStyle(.primary)
                                        if !ingredient.category.isEmpty {
                                            Text(ingredient.category)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedBaseIngredient?.id == ingredient.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else if !isSearching {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Browse the first page of catalog ingredients or search for a specific one." : "No matching ingredients found.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if selectedBaseIngredient != nil {
                    let isAvoidance = IngredientChoiceMode(rawValue: choiceMode)?.isAvoidance ?? false
                    Section("Preference") {
                        Picker("Choice mode", selection: $choiceMode) {
                            ForEach(IngredientChoiceMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }

                        if isAvoidance {
                            Text(choiceMode == "allergy"
                                ? "The AI will never include this ingredient in any generated meal plan."
                                : "The AI will skip this ingredient when planning your week. Substitutes will be suggested if a saved recipe requires it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            if isLoadingVariations {
                                ProgressView("Loading product variations…")
                            } else if !variations.isEmpty {
                                Picker("Preferred variation", selection: $preferredVariationID) {
                                    Text("None").tag("")
                                    ForEach(variations) { variation in
                                        Text(variationLabel(for: variation)).tag(variation.id)
                                    }
                                }
                            } else {
                                Text("No stored product variations yet for this ingredient.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            TextField("Preferred brand", text: $preferredBrand)
                                .textInputAutocapitalization(.words)

                            Picker("Rank", selection: $rank) {
                                Text("Primary").tag(1)
                                Text("Secondary").tag(2)
                                Text("Tertiary").tag(3)
                            }
                            .pickerStyle(.segmented)
                        }

                        Toggle("Active", isOn: $isActive)

                        TextField("Notes", text: $notes, axis: .vertical)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(context.preference == nil ? "New Preference" : "Edit Preference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await savePreference() }
                    }
                    .disabled(isSaving || selectedBaseIngredient == nil)
                }
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                await loadInitialState()
            }
        }
    }

    private func loadInitialState() async {
        let baseIngredientName = context.preference?.baseIngredientName ?? context.seedBaseIngredientName
        let baseIngredientID = context.preference?.baseIngredientId ?? context.seedBaseIngredientID
        do {
            searchResults = try await appState.searchBaseIngredients(query: baseIngredientName ?? "", limit: 50)
            if let baseIngredientID,
               let matched = searchResults.first(where: { $0.baseIngredientId == baseIngredientID }) {
                await selectBaseIngredient(matched)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func searchIngredients() async {
        do {
            isSearching = true
            errorMessage = nil
            searchResults = try await appState.searchBaseIngredients(query: searchText, limit: 50)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func selectBaseIngredient(_ ingredient: BaseIngredient) async {
        selectedBaseIngredient = ingredient
        do {
            isLoadingVariations = true
            variations = try await appState.fetchIngredientVariations(baseIngredientID: ingredient.baseIngredientId)
            if !preferredVariationID.isEmpty,
               !variations.contains(where: { $0.ingredientVariationId == preferredVariationID }) {
                preferredVariationID = ""
            }
        } catch {
            variations = []
            errorMessage = error.localizedDescription
        }
        isLoadingVariations = false
    }

    private func savePreference() async {
        guard let selectedBaseIngredient else { return }
        do {
            isSaving = true
            // Avoid/allergy modes don't have brand or variation fields —
            // blank them on save so stale data from a prior "preferred"
            // state doesn't linger.
            let isAvoidance = IngredientChoiceMode(rawValue: choiceMode)?.isAvoidance ?? false
            _ = try await appState.upsertIngredientPreference(
                preferenceID: context.preference?.preferenceId,
                baseIngredientID: selectedBaseIngredient.baseIngredientId,
                preferredVariationID: isAvoidance
                    ? nil
                    : (preferredVariationID.isEmpty ? nil : preferredVariationID),
                preferredBrand: isAvoidance
                    ? ""
                    : preferredBrand.trimmingCharacters(in: .whitespacesAndNewlines),
                choiceMode: choiceMode,
                active: isActive,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                rank: isAvoidance ? 1 : rank
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func variationLabel(for variation: IngredientVariation) -> String {
        if variation.brand.isEmpty {
            return variation.name
        }
        return "\(variation.brand) • \(variation.name)"
    }
}

struct IngredientCatalogSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let selectIngredient: (BaseIngredient) -> Void

    @State private var searchText = ""
    @State private var ingredients: [BaseIngredient] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search ingredients", text: $searchText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit {
                            Task { await loadIngredients() }
                        }

                    Button {
                        Task { await loadIngredients() }
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Search Catalog")
                        }
                    }
                    .disabled(isLoading)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("Base Ingredients") {
                    if ingredients.isEmpty, !isLoading {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No base ingredients found yet." : "No ingredients matched that search.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ingredients) { ingredient in
                            Button {
                                selectIngredient(ingredient)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ingredient.name)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 8) {
                                        if !ingredient.category.isEmpty {
                                            Text(ingredient.category)
                                        }
                                        if !ingredient.defaultUnit.isEmpty {
                                            Text("Unit: \(ingredient.defaultUnit)")
                                        }
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Ingredient Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                guard ingredients.isEmpty else { return }
                await loadIngredients()
            }
        }
    }

    private func loadIngredients() async {
        do {
            isLoading = true
            errorMessage = nil
            ingredients = try await appState.searchBaseIngredients(query: searchText, limit: 100)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private enum IngredientChoiceMode: String, CaseIterable, Identifiable {
    case preferred
    case cheapest
    case bestReviewed = "best_reviewed"
    case rotate
    case noPreference = "no_preference"
    case avoid
    case allergy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferred: "Preferred"
        case .cheapest: "Cheapest"
        case .bestReviewed: "Best Reviewed"
        case .rotate: "Rotate"
        case .noPreference: "No Preference"
        case .avoid: "Avoid"
        case .allergy: "Allergy"
        }
    }

    /// True for modes where the planner should never propose the
    /// ingredient. Controls whether the editor shows brand/variation
    /// fields — those make no sense for an ingredient the user wants to
    /// stay away from.
    var isAvoidance: Bool {
        switch self {
        case .avoid, .allergy: true
        default: false
        }
    }
}

private extension IngredientPreference {
    /// Convenience so views don't need to compare raw strings.
    var isAvoidance: Bool {
        choiceMode == "avoid" || choiceMode == "allergy"
    }
}

private func rankLabel(_ rank: Int) -> String {
    switch rank {
    case 1: return "Primary"
    case 2: return "Secondary"
    case 3: return "Tertiary"
    default: return "#\(rank)"
    }
}


/// Pill next to the preference row's title. Amber for plain avoids,
/// red for allergies — user can eyeball the whole list for anything
/// the planner must never propose.
@ViewBuilder
private func preferencePill(for choiceMode: String) -> some View {
    switch choiceMode {
    case "allergy":
        Text("Allergy")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.red.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.red)
    case "avoid":
        Text("Avoid")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.orange)
    default:
        Text(choiceMode.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption)
            .foregroundStyle(SMColor.textSecondary)
    }
}

// MARK: - Household Section (M21)

private struct HouseholdSection: View {
    @Environment(AppState.self) private var appState
    @State private var showInviteSheet = false
    @State private var inviteCode: String = ""
    @State private var inviteExpiresAt: Date?
    @State private var showJoinSheet = false
    @State private var renameDraft: String = ""
    @State private var didLoadRenameDraft = false

    var body: some View {
        Section {
            if let household = appState.currentHousehold {
                if household.isOwner {
                    TextField("Household name", text: $renameDraft, prompt: Text("e.g. The Smiths"))
                        .submitLabel(.done)
                        .onSubmit {
                            let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && trimmed != household.name {
                                Task { await appState.renameHousehold(trimmed) }
                            }
                        }
                } else if !household.name.isEmpty {
                    LabeledContent("Name", value: household.name)
                }

                ForEach(household.members) { member in
                    HStack {
                        Text(memberLabel(member, household: household))
                            .font(SMFont.subheadline)
                        Spacer()
                        Text(member.role.capitalized)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }

                if household.isOwner {
                    Button {
                        Task {
                            if let code = await appState.createHouseholdInvitation() {
                                inviteCode = code
                                let expiry = appState.currentHousehold?
                                    .activeInvitations
                                    .first(where: { $0.code == code })?
                                    .expiresAt
                                inviteExpiresAt = expiry
                                showInviteSheet = true
                            }
                        }
                    } label: {
                        Label("Invite a member", systemImage: "person.badge.plus")
                    }

                    if !household.activeInvitations.isEmpty {
                        ForEach(household.activeInvitations) { invitation in
                            HStack {
                                Text(invitation.code)
                                    .font(.system(.subheadline, design: .monospaced))
                                Spacer()
                                Button(role: .destructive) {
                                    Task {
                                        await appState.revokeHouseholdInvitation(code: invitation.code)
                                    }
                                } label: {
                                    Text("Revoke")
                                        .font(SMFont.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                }

                if household.isSolo {
                    Button {
                        showJoinSheet = true
                    } label: {
                        Label("Join a household", systemImage: "person.2.fill")
                    }
                }
            } else {
                Text("Loading household…")
                    .foregroundStyle(SMColor.textTertiary)
            }
        } header: {
            SmithSectionHeader("household")
        }
        .onAppear {
            guard !didLoadRenameDraft else { return }
            didLoadRenameDraft = true
            renameDraft = appState.currentHousehold?.name ?? ""
            // Best-effort refresh in case bootstrap didn't load it yet.
            Task { await appState.refreshHousehold() }
        }
        .onChange(of: appState.currentHousehold?.name) { _, newName in
            // Keep the textfield in sync when the household renames externally.
            let value = newName ?? ""
            if value != renameDraft {
                renameDraft = value
            }
        }
        .sheet(isPresented: $showInviteSheet) {
            InvitationSheet(code: inviteCode, expiresAt: inviteExpiresAt)
        }
        .sheet(isPresented: $showJoinSheet) {
            JoinHouseholdSheet { code in
                await appState.joinHousehold(code: code)
            }
        }
    }

    private func memberLabel(_ member: HouseholdMember, household: HouseholdSnapshot) -> String {
        if member.userId == household.createdByUserId {
            return "You" + (member.role == "owner" ? "" : "")
        }
        // We don't have member names yet — show a short ID stub.
        let stub = String(member.userId.prefix(8))
        return "Member \(stub)"
    }
}

// MARK: - Grocery (M22)

private struct GrocerySection: View {
    @Environment(AppState.self) private var appState
    @State private var showingPicker = false
    @State private var selectedListName: String = ""
    @State private var permissionStatus: EKAuthorizationStatus = .notDetermined

    var body: some View {
        Section {
            // Build 87 — Savanne/Taylor dogfood: the old "edit a meal,
            // grocery list auto-rebuilds" behavior is OFF by default
            // now. Adding meals leaves the list alone; the user opens
            // the plan-shopping sheet (Week or Grocery → "Plan
            // Shopping") and adds items they actually need. Flip this
            // back on to restore the old auto-add.
            Toggle("Auto-populate from meals", isOn: Binding(
                get: { appState.autoGroceryFromMeals },
                set: { newValue in
                    Task { await appState.saveAutoGroceryFromMeals(newValue) }
                }
            ))
            Text("When on, planning a meal automatically adds its ingredients to the grocery list. When off (the default), the list stays untouched — open Plan Shopping to add what you actually need.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Sync to Apple Reminders", isOn: Binding(
                get: { appState.reminderListIdentifier != nil },
                set: { newValue in
                    Task { await handleToggle(newValue) }
                }
            ))

            if let listID = appState.reminderListIdentifier {
                LabeledContent("Reminders list") {
                    Text(selectedListName.isEmpty ? "—" : selectedListName)
                        .foregroundStyle(.secondary)
                }
                Button("Change list") { showingPicker = true }
            }

            if appState.reminderListIdentifier != nil {
                Button {
                    Task {
                        // Pull first (catches items added directly in
                        // Reminders.app, plus check-state diffs), then
                        // push so the SimmerSmith list re-mirrors out.
                        await appState.handleReminderStoreChange()
                        await appState.syncGroceryToReminders()
                    }
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
            }

            if let last = appState.lastReminderSyncAt {
                LabeledContent("Last synced") {
                    Text(last, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = appState.lastReminderSyncSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if permissionStatus == .denied || permissionStatus == .restricted {
                Text("Reminders access is denied. Open Settings → SimmerSmith → Reminders to enable.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            SmithSectionHeader("grocery sync")
        }
        .task { await refreshState() }
        .sheet(isPresented: $showingPicker, onDismiss: { Task { await refreshState() } }) {
            ReminderListPickerSheet()
                .environment(appState)
        }
    }

    private func handleToggle(_ enabled: Bool) async {
        if enabled {
            let granted = await appState.requestRemindersAccess()
            if !granted {
                await refreshState()
                return
            }
            // If the user hasn't picked a list yet, prompt the picker.
            if appState.reminderListIdentifier == nil {
                showingPicker = true
            } else {
                await appState.syncGroceryToReminders()
            }
        } else {
            appState.clearReminderList()
        }
        await refreshState()
    }

    private func refreshState() async {
        permissionStatus = RemindersService.shared.currentAuthorizationStatus()
        if let id = appState.reminderListIdentifier,
           let calendar = RemindersService.shared.calendar(identifier: id) {
            selectedListName = calendar.title
        } else {
            selectedListName = ""
        }
    }
}
