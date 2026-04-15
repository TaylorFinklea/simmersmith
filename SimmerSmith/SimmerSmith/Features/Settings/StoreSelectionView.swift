import SwiftUI
import SimmerSmithKit

struct StoreSelectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var zipCode = ""
    @State private var stores: [StoreLocation] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var selectedStoreID: String = ""

    var body: some View {
        Form {
            Section("Search by Zip Code") {
                HStack {
                    TextField("Zip code", text: $zipCode)
                        .keyboardType(.numberPad)
                        .textContentType(.postalCode)

                    Button {
                        Task { await searchStores() }
                    } label: {
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Search")
                        }
                    }
                    .disabled(zipCode.count < 5 || isSearching)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.destructive)
                }
            }

            if !stores.isEmpty {
                Section("Nearby Stores") {
                    ForEach(stores) { store in
                        Button {
                            selectedStoreID = store.locationId
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.name)
                                        .font(SMFont.body)
                                        .foregroundStyle(SMColor.textPrimary)
                                    Text("\(store.address), \(store.city), \(store.state) \(store.zipCode)")
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textSecondary)
                                    if !store.chain.isEmpty, store.chain != store.name {
                                        Text(store.chain)
                                            .font(.caption2)
                                            .foregroundStyle(SMColor.textTertiary)
                                    }
                                }

                                Spacer()

                                if selectedStoreID == store.locationId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(SMColor.primary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !selectedStoreID.isEmpty {
                Section {
                    Button("Save Store") {
                        Task { await saveStore() }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(SMColor.primary)
                    .font(SMFont.subheadline)
                }
            }

            if let currentStore = currentStoreName {
                Section("Current Store") {
                    Text(currentStore)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textPrimary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SMColor.surface)
        .navigationTitle("Select Store")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedStoreID = appState.profile?.settings["kroger_location_id"] ?? ""
        }
    }

    private var currentStoreName: String? {
        guard let id = appState.profile?.settings["kroger_location_id"], !id.isEmpty else {
            return nil
        }
        if let name = appState.profile?.settings["kroger_store_name"], !name.isEmpty {
            return "\(name) (\(id))"
        }
        return "Store \(id)"
    }

    private func searchStores() async {
        isSearching = true
        errorMessage = nil
        do {
            stores = try await appState.apiClient.searchStores(zipCode: zipCode)
            if stores.isEmpty {
                errorMessage = "No stores found near \(zipCode)."
            }
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
        isSearching = false
    }

    private func saveStore() async {
        guard !selectedStoreID.isEmpty else { return }
        let storeName = stores.first(where: { $0.locationId == selectedStoreID })?.displayName ?? ""
        do {
            _ = try await appState.apiClient.updateProfile(settings: [
                "kroger_location_id": selectedStoreID,
                "kroger_store_name": storeName,
            ])
            await appState.refreshAll()
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}
