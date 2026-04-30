import SwiftUI
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
            Section("Server") {
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
            }

            Section("Sync") {
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
            }

            Section("AI") {
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
            }

            Section("Recipe images") {
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
            }

            NotificationsSection()

            Section("Templates") {
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
            }

            Section("Grocery") {
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
                Text("Location")
            } footer: {
                Text("Used for the in-season produce snapshot on the Week tab. Free-form — try \"Kansas, USA\" or \"Northern California\".")
                    .font(.footnote)
            }

            Section("Nutrition") {
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
            }

            Section("Subscription") {
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
            }

            Section("Ingredient Preferences") {
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
            }

            Section("Ingredients") {
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
                Text("Guests")
            } footer: {
                Text("Your reusable guest list for the Events tab. Age group + allergies shape menu generation.")
            }

            Section("Notifications") {
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
            }

            Section("Data") {
                Button("Clear Local Cache", role: .destructive) {
                    appState.clearLocalCache()
                }

                Button("Reset Connection", role: .destructive) {
                    appState.resetConnection()
                }
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
        .background(SMColor.surface)
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
                Text("Settings")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(SMColor.primary)
            }
        }
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

// MARK: - Notifications Section (M18)

private struct NotificationsSection: View {
    @Environment(AppState.self) private var appState

    // Local date state mirrors the profile string. Initialised lazily.
    @State private var tonightsMealDate: Date = NotificationsSection.dateFromTimeString("17:00")
    @State private var saturdayPlanDate: Date = NotificationsSection.dateFromTimeString("18:00")
    @State private var didInitDates = false

    var body: some View {
        Section {
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
        } header: {
            Text("Notifications")
        } footer: {
            Text("On by default — toggle off to silence. We send push only at the times you set. Quiet hours: never between 22:00–07:00 local. If you previously denied notifications, enable them in iOS Settings \u{2192} Notifications \u{2192} SimmerSmith.")
                .font(.footnote)
        }
        .onAppear {
            guard !didInitDates else { return }
            didInitDates = true
            tonightsMealDate = NotificationsSection.dateFromTimeString(appState.pushTonightsMealTime)
            saturdayPlanDate = NotificationsSection.dateFromTimeString(appState.pushSaturdayPlanTime)
        }
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
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
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
