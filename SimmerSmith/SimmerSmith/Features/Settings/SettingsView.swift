import SwiftUI
import SimmerSmithKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var preferenceEditor: IngredientPreferenceEditorContext?
    @State private var ingredientCatalogPresented = false

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
                    .foregroundStyle(.secondary)

                if let updatedAt = appState.currentWeek?.updatedAt {
                    LabeledContent("Current week") {
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let updatedAt = appState.profile?.updatedAt {
                    LabeledContent("Profile") {
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
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
                        }
                    } else {
                        Text(appState.assistantExecutionStatusText)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Preferred mode") {
                        Text(capabilities.preferredMode.capitalized)
                    }
                    LabeledContent("User override") {
                        Text(capabilities.userOverrideConfigured ? "Configured" : "Not configured")
                    }
                    ForEach(capabilities.availableProviders) { provider in
                        LabeledContent(provider.label) {
                            Text(provider.available ? provider.source.replacingOccurrences(of: "_", with: " ").capitalized : "Unavailable")
                                .foregroundStyle(provider.available ? .secondary : .tertiary)
                        }
                    }
                } else {
                    Text(appState.assistantExecutionStatusText)
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Discovering available models for the selected provider…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)

                Button("Save AI Settings") {
                    Task { await appState.saveAISettings() }
                }

                Button("Clear Stored API Key", role: .destructive) {
                    Task { await appState.saveAISettings(clearStoredAPIKey: true) }
                }
                .disabled(!appState.aiDirectAPIKeyConfigured)
            }

            Section("Templates") {
                LabeledContent("Recipe templates") {
                    Text("\(appState.recipeTemplateCount)")
                }
                if let defaultTemplate = appState.recipeMetadata?.templates.first(where: { $0.templateId == appState.recipeMetadata?.defaultTemplateId }) {
                    LabeledContent("Default template") {
                        Text(defaultTemplate.name)
                    }
                } else {
                    Text("Template library syncs with recipe metadata.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Ingredient Preferences") {
                if appState.ingredientPreferences.isEmpty {
                    Text("Set household defaults like a preferred biscuit brand or whether to pick the cheapest option.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.ingredientPreferences) { preference in
                        Button {
                            preferenceEditor = IngredientPreferenceEditorContext(preference: preference)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(preference.baseIngredientName)
                                        .foregroundStyle(.primary)
                                    if !preference.active {
                                        Text("Inactive")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(.thinMaterial, in: Capsule())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(preference.choiceMode.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let variationName = preference.preferredVariationName, !variationName.isEmpty {
                                    Text(variationName)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else if !preference.preferredBrand.isEmpty {
                                    Text(preference.preferredBrand)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Generic ingredient preference")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
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
                Text("Browse the canonical ingredient catalog, then seed or edit household preferences from real ingredients instead of guessing search terms.")
                    .foregroundStyle(.secondary)

                Button {
                    ingredientCatalogPresented = true
                } label: {
                    Label("Browse Ingredient Catalog", systemImage: "square.stack.3d.up")
                }
            }

            Section("Data") {
                Button("Clear Local Cache", role: .destructive) {
                    appState.clearLocalCache()
                }

                Button("Reset Connection", role: .destructive) {
                    appState.resetConnection()
                }
            }
        }
        .navigationTitle("Settings")
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
        .sheet(isPresented: $ingredientCatalogPresented) {
            IngredientCatalogSheet { ingredient in
                ingredientCatalogPresented = false
                preferenceEditor = IngredientPreferenceEditorContext(
                    seedBaseIngredientID: ingredient.baseIngredientId,
                    seedBaseIngredientName: ingredient.name
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BrandToolbarBadge()
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
                    Section("Preference") {
                        Picker("Choice mode", selection: $choiceMode) {
                            ForEach(IngredientChoiceMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }

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
            guard let baseIngredientName else { return }
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
            _ = try await appState.upsertIngredientPreference(
                preferenceID: context.preference?.preferenceId,
                baseIngredientID: selectedBaseIngredient.baseIngredientId,
                preferredVariationID: preferredVariationID.isEmpty ? nil : preferredVariationID,
                preferredBrand: preferredBrand.trimmingCharacters(in: .whitespacesAndNewlines),
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferred:
            "Preferred"
        case .cheapest:
            "Cheapest"
        case .bestReviewed:
            "Best Reviewed"
        case .rotate:
            "Rotate"
        case .noPreference:
            "No Preference"
        }
    }
}
