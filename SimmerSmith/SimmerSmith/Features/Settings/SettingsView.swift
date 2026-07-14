import AuthenticationServices
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
    @State private var geminiImageKeyDraft: String = ""
    /// Build 91 — Reminders picker presentation lives at the SettingsView
    /// level (not inside GrocerySection) because iOS 26 dismisses a
    /// sheet-attached-to-a-Section within ~1s if the Section re-renders
    /// during presentation (the async permission grant + state refresh
    /// in the old Toggle.set was the trigger). Hosting the sheet on the
    /// top-level NavigationStack body avoids that race.
    @State private var showingReminderPicker = false
    @State private var isTestingAIKey = false
    @State private var aiKeyTestResult: String?
    /// Confirmation-dialog presentation state for the "data" section's
    /// destructive buttons + Sign Out — mirrors `StartFreshSection`'s
    /// pattern so every destructive action states its consequence before
    /// firing instead of executing instantly.
    @State private var showingClearCacheConfirmation = false
    @State private var showingResetConnectionConfirmation = false
    @State private var showingSignOutConfirmation = false
    /// simmersmith-224 — Settings shows the *whole* catalog, not just the
    /// unseen slice the launch sheet shows. Nothing here marks notes as seen;
    /// that is the launch sheet's job alone.
    @State private var showingReleaseNotes = false

    private var appVersionDisplay: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        @Bindable var appState = appState

        Form {
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
                    Task {
                        await appState.refreshHouseholdFromCloud()   // CloudKit pull (owner + participant)
                        await appState.refreshAll()                  // legacy Fly path (no-op in CloudKit-only)
                    }
                }

                // simmersmith-qrt: engine-level CloudKit sync status — distinct from
                // `syncStatusText` above (the legacy Fly-era `syncPhase`, which never
                // carries CloudKit failure detail). Surfaces a permanently-failed save or
                // a stalled participant join instead of leaving them invisible.
                #if canImport(CloudKit)
                NavigationLink {
                    SyncStatusDetailView()
                } label: {
                    HStack {
                        Label("iCloud Sync", systemImage: "icloud")
                        Spacer()
                        Text(appState.syncStatusCenter.derivation.statusLine)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                #endif
            } header: {
                SmithSectionHeader("sync")
            }

            HouseholdSection()

            GrocerySection(presentReminderPicker: { showingReminderPicker = true })

            TopBarSection()

            ForgeSection()

            // SP-C AI-1: BYO-key AI settings section.
            // Provider/model → private plane (KeychainKeyStore for the key).
            // "Test key" validates via a cheap models-list call.
            Section {
                Picker("Provider", selection: $appState.aiDirectProviderDraft) {
                    Text("None").tag("")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                    // Open models keeps the internal "openmodels" tag while the row below
                    // selects Ollama Cloud or NeuralWatt plus that provider's model/key.
                    Text("Open models").tag("openmodels")
                }
                .onChange(of: appState.aiDirectProviderDraft) { _, newValue in
                    // Commit the displayed Ollama Cloud default so a default-accept user keys +
                    // saves a resolvable config without having to open the model dropdown first.
                    if newValue == "openmodels" { appState.seedOpenModelsDefaultsIfNeeded() }
                }

                if !appState.aiDirectProviderDraft.isEmpty {
                    // SP-C — model selection is a key-aware dropdown: the provider's
                    // live /v1/models (curated) with a static fallback. "Open models"
                    // first chooses Ollama Cloud or NeuralWatt, then a model + Custom….
                    if appState.aiDirectProviderDraft == "openmodels" {
                        OpenModelsPickerRow()
                    } else {
                        AIModelPickerRow(provider: appState.aiDirectProviderDraft)
                    }

                    // Key status (read from Keychain — never from Fly).
                    HStack(spacing: 6) {
                        Image(systemName: appState.aiDirectAPIKeyConfigured ? "key.fill" : "key.slash")
                            .foregroundStyle(appState.aiDirectAPIKeyConfigured ? SMColor.success : SMColor.textTertiary)
                            .imageScale(.small)
                        Text(ckApiKeyStatusText)
                            .font(.footnote)
                            .foregroundStyle(appState.aiDirectAPIKeyConfigured ? SMColor.textSecondary : .orange)
                    }

                    SecureField(
                        "New \(appState.selectedAIDisplayLabel) API key",
                        text: $appState.aiDirectAPIKeyDraft
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Button("Save AI Settings") {
                    Task { await appState.saveAISettings() }
                }

                if !appState.aiDirectProviderDraft.isEmpty && appState.aiDirectAPIKeyConfigured {
                    Button {
                        Task { await runTestKey() }
                    } label: {
                        HStack {
                            if isTestingAIKey { ProgressView().controlSize(.small) }
                            Text(isTestingAIKey ? "Testing…" : "Test Key")
                        }
                    }
                    .disabled(isTestingAIKey)
                }

                if let result = aiKeyTestResult {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(result.contains("valid") ? SMColor.success : .red)
                }

                if !appState.aiDirectProviderDraft.isEmpty && appState.aiDirectAPIKeyConfigured {
                    Button("Clear Stored API Key", role: .destructive) {
                        Task { await appState.saveAISettings(clearStoredAPIKey: true) }
                    }
                }

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

                // SP-C — customize the assistant's per-screen suggestion chips.
                NavigationLink {
                    AssistantPromptsView()
                } label: {
                    Label("Assistant prompts", systemImage: "text.bubble")
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
            } footer: {
                Text("Your API key is saved locally to this device's Keychain — it is never sent to SimmerSmith's servers or iCloud.")
                    .font(.footnote)
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

                Text("Affects new recipes. Existing images stay unchanged.")
                    .font(.footnote)
                    .foregroundStyle(SMColor.textSecondary)

                // SP-C AI-4: image-provider key UX.
                // OpenAI images reuse the OpenAI text key (shown in the AI section above).
                // Gemini images need a separate Gemini key entered here.
                if appState.imageProviderDraft == "gemini" {
                    HStack(spacing: 6) {
                        Image(systemName: appState.geminiImageKeyConfigured ? "key.fill" : "key.slash")
                            .foregroundStyle(appState.geminiImageKeyConfigured ? SMColor.success : SMColor.textTertiary)
                            .imageScale(.small)
                        Text(appState.geminiImageKeyConfigured
                             ? "Gemini key saved in this device's Keychain."
                             : "No Gemini key saved yet. Enter your key below and tap Save.")
                            .font(.footnote)
                            .foregroundStyle(appState.geminiImageKeyConfigured ? SMColor.textSecondary : .orange)
                    }
                    SecureField("Gemini API key", text: $geminiImageKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Gemini Image Key") {
                        appState.saveGeminiImageKey(geminiImageKeyDraft)
                        geminiImageKeyDraft = ""
                    }
                    .disabled(geminiImageKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if appState.geminiImageKeyConfigured {
                        Button("Clear Gemini Image Key", role: .destructive) {
                            appState.clearGeminiImageKey()
                        }
                    }
                } else {
                    // OpenAI image key = the OpenAI text key. Show its status here so the
                    // user doesn't have to scroll up to the AI section to check.
                    HStack(spacing: 6) {
                        Image(systemName: appState.providerAPIKeyConfigured(providerID: "openai") ? "key.fill" : "key.slash")
                            .foregroundStyle(appState.providerAPIKeyConfigured(providerID: "openai") ? SMColor.success : SMColor.textTertiary)
                            .imageScale(.small)
                        Text(appState.providerAPIKeyConfigured(providerID: "openai")
                             ? "OpenAI key saved (shared with the AI section above)."
                             : "No OpenAI key saved yet. Add it in the AI section above.")
                            .font(.footnote)
                            .foregroundStyle(appState.providerAPIKeyConfigured(providerID: "openai") ? SMColor.textSecondary : .orange)
                    }
                }

                // simmersmith-xwb stage 1: hidden — RecipeHeaderImage never renders a
                // photo, so this bulk backfill wrote AI spend nobody could see.
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

            // MonetizationFlags.paywallEnabled == false darkens the paywall: an
            // entitled user (grandfathered from before the darkening, or a
            // manual StoreKit sandbox test) still sees their Pro status, but
            // nobody else sees an upgrade path — the section disappears
            // entirely rather than showing a dead "Upgrade to Pro" button.
            if MonetizationFlags.paywallEnabled || appState.isPro {
                Section {
                    if appState.isPro {
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
                Button("Clear Local Cache", role: .destructive) {
                    showingClearCacheConfirmation = true
                }
                .confirmationDialog(
                    "Clear Local Cache?",
                    isPresented: $showingClearCacheConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear Cache", role: .destructive) {
                        appState.clearLocalCache()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clears data cached on this device only. Nothing on iCloud is touched — your weeks, recipes, and events re-sync automatically.")
                }

                Button("Reset Connection", role: .destructive) {
                    showingResetConnectionConfirmation = true
                }
                .confirmationDialog(
                    "Reset Connection?",
                    isPresented: $showingResetConnectionConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset Connection", role: .destructive) {
                        appState.resetConnection()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This tears down your sync session and clears local data on this device. Data on iCloud is preserved and will re-sync the next time you sign in.")
                }
            } header: {
                SmithSectionHeader("data")
            }

            #if canImport(CloudKit)
            if appState.householdSession != nil {
                BackupRestoreSection()
            }
            #endif

            Section {
                Button(role: .destructive) {
                    showingSignOutConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Out")
                            .font(SMFont.subheadline)
                        Spacer()
                    }
                }
                .confirmationDialog(
                    "Sign Out?",
                    isPresented: $showingSignOutConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        appState.resetConnection()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This tears down your sync session and clears local data on this device. Data on iCloud is preserved and will re-sync when you sign back in.")
                }
            }

            #if canImport(CloudKit)
            if appState.householdSession != nil, appState.hasSavedConnection || appState.hasLegacyFlyEvidence {
                ImportWeeksSection()
                ImportEventsSection()
                ImportPantryProfileSection()
                StartFreshSection()
            }
            #endif

            // simmersmith-224: the durable way back to the release notes, and
            // the only place the app states which build it is — the first thing
            // any bug report needs.
            Section {
                Button {
                    showingReleaseNotes = true
                } label: {
                    HStack {
                        Label("What's New", systemImage: "sparkles")
                        Spacer()
                        Text(appVersionDisplay)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }
            } header: {
                SmithSectionHeader("about")
            }

            if DebugGate.showsCloudKitChecks {
                Section {
                    NavigationLink {
                        CloudKitDebugView()
                    } label: {
                        Label("CloudKit checks", systemImage: "cloud")
                    }
                } header: {
                    SmithSectionHeader("developer")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.ingredientPreferences.isEmpty {
                await appState.refreshIngredientPreferences()
            }
        }
        .sheet(isPresented: $showingReleaseNotes) {
            ReleaseNotesSheet(notes: ReleaseNotesCatalog.all)
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
        // Build 91 — Reminders list picker hoisted from GrocerySection.
        // See showingReminderPicker comment on the @State declaration.
        .sheet(isPresented: $showingReminderPicker) {
            ReminderListPickerSheet()
                .environment(appState)
        }
        .task {
            if appState.guests.isEmpty {
                await appState.refreshGuests()
            }
        }
        #if canImport(CloudKit)
        .task {
            // simmersmith-8o7 fix: probe for legacy-Fly evidence unconditionally,
            // independent of the Import*/Start Fresh gate below (line ~610). That
            // gate is `hasSavedConnection || hasLegacyFlyEvidence`, and the ONLY
            // other call site for `refreshWeekImportState()` lives inside
            // `ImportWeeksSection.onAppear` — a view that only renders once the
            // gate is already true. A migrated household whose device never had
            // `hasSavedConnection == true` locally (new/second device signed into
            // the same CloudKit account after migration happened elsewhere, a
            // fresh reinstall, etc.) could never flip the marker, so the recovery
            // sections stayed hidden forever. Calling it here — unconditionally,
            // whenever Settings appears — lets the receipt check run regardless
            // of the gate's current state.
            appState.refreshWeekImportState()
        }
        #endif
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

    /// SP-C AI-1: Key status reads from Keychain (not Fly secretFlags).
    private var ckApiKeyStatusText: String {
        guard !appState.aiDirectProviderDraft.isEmpty else {
            return "Select a provider to manage its API key."
        }
        let label = appState.selectedAIDisplayLabel
        return appState.aiDirectAPIKeyConfigured
            ? "\(label) API key saved in this device's Keychain."
            : "No \(label) API key saved yet. Enter your key above and tap Save."
    }

    private func runTestKey() async {
        isTestingAIKey = true
        aiKeyTestResult = nil
        defer { isTestingAIKey = false }
        aiKeyTestResult = await appState.testAIKey()
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
    @State private var renameDraft: String = ""
    @State private var didLoadRenameDraft = false

    var body: some View {
        Section {
            // Fly household display (name / members / rename) — only when a Fly snapshot
            // exists. In CloudKit-only mode this is nil; the sharing controls below DO NOT
            // depend on it (they key off the CloudKit session) so they still render.
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
            }

            // SP-C sharing v1 — keyed on the CloudKit SESSION, not the Fly snapshot (which is
            // nil in CloudKit-only mode). The owner shares the whole household zone with one
            // partner via a zone-wide CKShare + the native share sheet.
            if appState.canShareHousehold {
                Button {
                    let name = appState.currentHousehold?.name ?? ""
                    Task {
                        if let package = await appState.prepareOwnerShare(
                            title: name.isEmpty ? "SimmerSmith household" : name) {
                            // Present the native share sheet directly from the top VC (embedding
                            // it in a SwiftUI .sheet made it flash + self-dismiss).
                            CloudSharingPresenter.present(share: package.share, container: package.container)
                        }
                    }
                } label: {
                    Label("Share with your partner", systemImage: "person.badge.plus")
                }
                Text("Sends an invite link. Your partner taps it to see and edit this household. They keep their own personal recipes separately.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            } else if appState.isParticipant {
                Label("You're in a shared household", systemImage: "person.2.fill")
                    .foregroundStyle(SMColor.textSecondary)
            }

            // Only show a loading hint when neither plane has anything to show yet.
            if appState.currentHousehold == nil && !appState.canShareHousehold && !appState.isParticipant {
                Text("Loading household…")
                    .foregroundStyle(SMColor.textTertiary)
            }

            // simmersmith-auc: leftover EMPTY households from earlier builds are deleted
            // silently on launch — the user never hears about them. One that holds REAL
            // records is a different animal: a genuine fork, not build residue, so it
            // survives cleanup and says so here. Absent in every normal case. No delete
            // button — offering to destroy a zone whose contents the user cannot inspect is
            // not a favor, and the data they can see is already the richest copy.
            if !appState.forkedHouseholdIDs.isEmpty {
                let count = appState.forkedHouseholdIDs.count
                Label("Extra household data", systemImage: "square.stack.3d.up.fill")
                    .foregroundStyle(SMColor.textSecondary)
                Text("Your kitchen opened from the household holding the most data. "
                    + "\(count) other CloudKit household\(count == 1 ? "" : "s") from an earlier "
                    + "install still hold\(count == 1 ? "s" : "") records — nothing was deleted.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
                Text(appState.forkedHouseholdIDs.joined(separator: ", "))
                    .font(SMFont.caption)
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
    /// Build 91 — picker sheet host is the SettingsView body, not us.
    /// Section-attached sheets are torn down when the Section
    /// re-renders during the async permission grant, which is what
    /// caused the "picker flashes then dismisses" bug.
    let presentReminderPicker: () -> Void
    @State private var selectedListName: String = ""
    @State private var permissionStatus: EKAuthorizationStatus = .notDetermined
    @State private var isConnecting = false

    var body: some View {
        Section {
            // Build 91 — explicit Connect / Disconnect buttons replace
            // the old Toggle. The toggle's binding round-trip (set
            // newValue → async permission grant → showingPicker = true
            // → SwiftUI rebuilds the Toggle's parent Section → sheet
            // gets dismissed within ~1s on iOS 26) was an unfixable
            // race with the section-attached sheet. Explicit buttons
            // have no binding feedback loop, and the picker sheet
            // lives on the SettingsView body now, so it survives any
            // GrocerySection re-render.
            if appState.reminderListIdentifier == nil {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Label(
                            isConnecting ? "Connecting…" : "Connect to Apple Reminders",
                            systemImage: "checklist"
                        )
                        Spacer()
                    }
                }
                .disabled(isConnecting)
            } else {
                LabeledContent("Apple Reminders") {
                    Text(selectedListName.isEmpty ? "Connected" : selectedListName)
                        .foregroundStyle(.secondary)
                }
                Button("Change list") { presentReminderPicker() }
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
                Button(role: .destructive) {
                    appState.clearReminderList()
                    Task { await refreshState() }
                } label: {
                    Label("Disconnect", systemImage: "link.slash")
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
        .onChange(of: appState.reminderListIdentifier) { _, _ in
            Task { await refreshState() }
        }
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        let granted = await appState.requestRemindersAccess()
        await refreshState()
        guard granted else { return }
        if appState.reminderListIdentifier == nil {
            presentReminderPicker()
        } else {
            await appState.syncGroceryToReminders()
        }
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

// MARK: - ImportWeeksSection (SP-C slice 3)

/// Settings section for the one-shot "Import my weeks from the old app" trigger.
///
/// Shows a `SignInWithAppleButton` to obtain a Fly JWT, then calls
/// `AppState.importWeeksFromFly(appleIdentityToken:)`. The section is only rendered
/// once a CloudKit household session is live (caller guard) and collapses to a
/// "Already imported" label once the `migrated:weeks` receipt is stamped.
///
/// The Apple sign-in is purely an auth mechanism here — it does NOT change the
/// everyday identity (CloudKit is the identity). The JWT is a one-shot credential
/// to call the Fly /api/weeks endpoint; it is discarded after the import completes.
#if canImport(CloudKit)
private struct ImportWeeksSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            switch appState.weekImportState {
            case .alreadyImported:
                Label("Weeks already imported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SMColor.textSecondary)
                    .font(SMFont.subheadline)

            case .done:
                Label("Weeks imported successfully", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SMColor.textPrimary)
                    .font(SMFont.subheadline)

            case .running:
                HStack {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.85)
                    Text("Importing weeks…")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textSecondary)
                }

            case .failed(let reason):
                VStack(alignment: .leading, spacing: SMSpacing.xs) {
                    Label("Import failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SMColor.destructive)
                        .font(SMFont.subheadline)
                    Text(reason)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
                importButton

            case .idle:
                importButton
            }
        } header: {
            SmithSectionHeader("import history")
        } footer: {
            if appState.weekImportState == .idle || appState.weekImportState.isFailed {
                Text("Sign in with your Apple ID to pull your week plans and grocery lists from the previous app version. This runs once and is receipt-gated — safe to retry.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
            }
        }
        .onAppear {
            appState.refreshWeekImportState()
        }
    }

    private var importButton: some View {
        SignInWithAppleButton(.signIn, onRequest: { request in
            request.requestedScopes = [.email]
        }, onCompletion: { result in
            Task { await handleAppleResult(result) }
        })
        .signInWithAppleButtonStyle(.white)
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .strokeBorder(SMColor.divider, lineWidth: 1)
        )
        .disabled(appState.weekImportState == .running)
        // The button's system label ("Sign in with Apple") is contextually explained
        // by the section header ("import history") and footer text above, so no
        // custom label is needed.
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                appState.weekImportState = .failed("Could not read Apple identity token.")
                return
            }
            await appState.importWeeksFromFly(appleIdentityToken: token)

        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appState.weekImportState = .failed(error.localizedDescription)
        }
    }
}

extension AppState.WeekImportState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - ImportEventsSection (SP-C slice 4)

/// Settings section for the one-shot "Import my events + guests from the old app" trigger.
///
/// Mirrors `ImportWeeksSection` exactly, bound to `eventImportState` / `importEventsFromFly` /
/// `refreshEventImportState`. GATED on the weeks import having run first: migrated event-grocery
/// rows point at week GroceryItem records the WEEKS migration creates, so until the
/// `migrated:weeks` receipt is present the import button is replaced by an "import weeks first"
/// disabled prompt.
private struct ImportEventsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            switch appState.eventImportState {
            case .alreadyImported:
                Label("Events already imported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SMColor.textSecondary)
                    .font(SMFont.subheadline)

            case .done:
                Label("Events imported successfully", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SMColor.textPrimary)
                    .font(SMFont.subheadline)

            case .running:
                HStack {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.85)
                    Text("Importing events…")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textSecondary)
                }

            case .failed(let reason):
                VStack(alignment: .leading, spacing: SMSpacing.xs) {
                    Label("Import failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SMColor.destructive)
                        .font(SMFont.subheadline)
                    Text(reason)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
                gatedImportControl

            case .idle:
                gatedImportControl
            }
        } header: {
            SmithSectionHeader("import events")
        } footer: {
            if !appState.weeksImportComplete {
                Text("Import your weeks first — event grocery lists merge into your weekly lists, so the weeks need to be in place before events are imported.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
            } else if appState.eventImportState == .idle || appState.eventImportState.isFailed {
                Text("Sign in with your Apple ID to pull your events, guests, and event grocery lists from the previous app version. This runs once and is receipt-gated — safe to retry.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
            }
        }
        .onAppear {
            appState.refreshEventImportState()
        }
    }

    /// The import control, gated on the weeks import having completed. Until then it shows a
    /// disabled "import weeks first" label instead of the Apple sign-in button.
    @ViewBuilder
    private var gatedImportControl: some View {
        if appState.weeksImportComplete {
            importButton
        } else {
            Label("Import weeks first", systemImage: "lock.fill")
                .foregroundStyle(SMColor.textTertiary)
                .font(SMFont.subheadline)
        }
    }

    private var importButton: some View {
        SignInWithAppleButton(.signIn, onRequest: { request in
            request.requestedScopes = [.email]
        }, onCompletion: { result in
            Task { await handleAppleResult(result) }
        })
        .signInWithAppleButtonStyle(.white)
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .strokeBorder(SMColor.divider, lineWidth: 1)
        )
        .disabled(appState.eventImportState == .running)
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                appState.eventImportState = .failed("Could not read Apple identity token.")
                return
            }
            await appState.importEventsFromFly(appleIdentityToken: token)

        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appState.eventImportState = .failed(error.localizedDescription)
        }
    }
}

extension AppState.EventImportState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - ImportPantryProfileSection (SP-C slice 5)

/// Settings section for the one-shot "Import my pantry + profile + prefs" trigger.
///
/// Mirrors `ImportWeeksSection` / `ImportEventsSection` in structure. Bound to
/// `pantryProfileImportState` / `importPantryProfileFromFly` / `refreshPantryProfileImportState`.
///
/// Receipt is a PRIVATE-PLANE receipt (not a household zone receipt) because the profile
/// and ingredient-preference data is per-user (private plane), not household-shared.
/// The migration also writes pantry items and aliases to the household zone, but the
/// private-plane receipt is the single gate for the whole bundle.
private struct ImportPantryProfileSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            switch appState.pantryProfileImportState {
            case .alreadyImported:
                Label("Pantry & profile already imported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SMColor.textSecondary)
                    .font(SMFont.subheadline)

            case .done:
                Label("Pantry & profile imported successfully", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SMColor.textPrimary)
                    .font(SMFont.subheadline)

            case .running:
                HStack {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.85)
                    Text("Importing pantry & profile…")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textSecondary)
                }

            case .failed(let reason):
                VStack(alignment: .leading, spacing: SMSpacing.xs) {
                    Label("Import failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SMColor.destructive)
                        .font(SMFont.subheadline)
                    Text(reason)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
                importButton

            case .idle:
                importButton
            }
        } header: {
            SmithSectionHeader("import pantry & profile")
        } footer: {
            if appState.pantryProfileImportState == .idle || appState.pantryProfileImportState.isFailed {
                Text("Sign in with your Apple ID to pull your pantry items, dietary goal, ingredient preferences, and household term aliases from the previous app version. This runs once and is receipt-gated — safe to retry.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
            }
        }
        .onAppear {
            appState.refreshPantryProfileImportState()
        }
    }

    private var importButton: some View {
        SignInWithAppleButton(.signIn, onRequest: { request in
            request.requestedScopes = [.email]
        }, onCompletion: { result in
            Task { await handleAppleResult(result) }
        })
        .signInWithAppleButtonStyle(.white)
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .strokeBorder(SMColor.divider, lineWidth: 1)
        )
        .disabled(appState.pantryProfileImportState == .running)
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                appState.pantryProfileImportState = .failed("Could not read Apple identity token.")
                return
            }
            await appState.importPantryProfileFromFly(appleIdentityToken: token)

        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appState.pantryProfileImportState = .failed(error.localizedDescription)
        }
    }
}

extension AppState.PantryProfileImportState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - StartFreshSection (SP-C factory-reset)

/// Destructive "Start Fresh from Fly" Settings section.
///
/// Explains that the action WIPES all CloudKit household data then re-imports
/// everything from Fly. A `.confirmationDialog` is presented before the Apple
/// sign-in button appears, so the user must explicitly acknowledge the wipe.
///
/// Auth pattern mirrors `ImportWeeksSection` exactly: the Apple identity token
/// is exchanged for a one-shot Fly JWT, the orchestration runs under that JWT,
/// then the JWT is discarded. The wipe never starts until the exchange succeeds
/// (auth-first ordering, spec §3 step 1).
private struct StartFreshSection: View {
    @Environment(AppState.self) private var appState

    /// Whether the user has acknowledged the confirmation dialog and the Apple
    /// sign-in button should now be shown.
    @State private var showingSignIn = false
    /// Whether the confirmation dialog is currently presented.
    @State private var showingConfirmation = false

    var body: some View {
        Section {
            switch appState.startFreshState {
            case .running(let progress):
                HStack {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.85)
                    Text(progress)
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textSecondary)
                }

            case .done(let result):
                resultView(result)

            case .failed(let reason):
                VStack(alignment: .leading, spacing: SMSpacing.xs) {
                    Label("Reset failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SMColor.destructive)
                        .font(SMFont.subheadline)
                    Text(reason)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
                resetControl

            case .idle:
                resetControl
            }
        } header: {
            SmithSectionHeader("danger zone")
        } footer: {
            switch appState.startFreshState {
            case .idle, .failed:
                Text("This deletes ALL your CloudKit household data on this account and re-imports everything fresh from Fly. Use this if your data looks wrong or duplicated. Your Fly data is never deleted — only the CloudKit copy is wiped.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
            default:
                EmptyView()
            }
        }
        .confirmationDialog(
            "Start Fresh from Fly?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Erase & Re-import", role: .destructive) {
                showingSignIn = true
            }
            Button("Cancel", role: .cancel) {
                showingSignIn = false
            }
        } message: {
            Text("This will permanently delete all your CloudKit households and re-import your data from Fly. You cannot undo the CloudKit wipe. Your Fly data is safe.")
        }
    }

    /// The control shown in `.idle` and `.failed` states: a destructive trigger
    /// button that raises the confirmation dialog, then (after confirmation) the
    /// Apple sign-in button.
    @ViewBuilder
    private var resetControl: some View {
        if showingSignIn {
            signInButton
        } else {
            Button(role: .destructive) {
                showingConfirmation = true
            } label: {
                Label("Start Fresh from Fly", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(appState.startFreshState.isRunning)
        }
    }

    private var signInButton: some View {
        SignInWithAppleButton(.signIn, onRequest: { request in
            request.requestedScopes = [.email]
        }, onCompletion: { result in
            Task { await handleAppleResult(result) }
        })
        .signInWithAppleButtonStyle(.white)
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .strokeBorder(SMColor.divider, lineWidth: 1)
        )
        .disabled(appState.startFreshState.isRunning)
    }

    @ViewBuilder
    private func resultView(_ result: AppState.StartFreshResult) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            Label("Re-import complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(SMColor.success)
                .font(SMFont.subheadline)

            let deletedCount = result.deletedHouseholdIDs.count
            LabeledContent("Zones cleared") {
                Text("\(deletedCount)")
                    .foregroundStyle(SMColor.textSecondary)
                    .monospacedDigit()
            }
            .font(SMFont.caption)

            LabeledContent("Ingredients") {
                Text(result.ingredientsImported ? "Imported" : "Not imported")
                    .foregroundStyle(result.ingredientsImported ? SMColor.success : SMColor.textTertiary)
            }
            .font(SMFont.caption)

            LabeledContent("Recipes") {
                Text(result.recipesImported ? "Imported" : "Not imported")
                    .foregroundStyle(result.recipesImported ? SMColor.success : SMColor.textTertiary)
            }
            .font(SMFont.caption)

            LabeledContent("Weeks") {
                Text(result.weeksImported ? "Imported" : "Not imported")
                    .foregroundStyle(result.weeksImported ? SMColor.success : SMColor.textTertiary)
            }
            .font(SMFont.caption)

            LabeledContent("Events") {
                Text(result.eventsImported ? "Imported" : "Not imported")
                    .foregroundStyle(result.eventsImported ? SMColor.success : SMColor.textTertiary)
            }
            .font(SMFont.caption)

            LabeledContent("Pantry & Profile") {
                Text(result.pantryProfileImported ? "Imported" : "Not imported")
                    .foregroundStyle(result.pantryProfileImported ? SMColor.success : SMColor.textTertiary)
            }
            .font(SMFont.caption)

            if let newID = result.newHouseholdID {
                LabeledContent("New household") {
                    Text(String(newID.prefix(8)) + "…")
                        .foregroundStyle(SMColor.textSecondary)
                        .monospacedDigit()
                }
                .font(SMFont.caption)
            }

            if !result.warnings.isEmpty {
                ForEach(result.warnings, id: \.self) { warning in
                    Text("⚠︎ \(warning)")
                        .font(SMFont.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                appState.startFreshState = .failed("Could not read Apple identity token.")
                return
            }
            showingSignIn = false
            await appState.startFreshFromFly(appleIdentityToken: token)

        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appState.startFreshState = .failed(error.localizedDescription)
        }
    }
}

extension AppState.StartFreshState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
#endif
