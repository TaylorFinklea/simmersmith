import SimmerSmithKit
import SwiftUI

/// Horizontal "what's in season now" chip strip rendered above the day
/// cards on the Week tab. Fed by `AppState.seasonalProduce`. Hidden when
/// the list is empty (AI errored or the user hasn't set a region).
struct InSeasonStrip: View {
    @Environment(AppState.self) private var appState
    @Binding var pickedItem: InSeasonItem?

    var body: some View {
        let items = appState.seasonalProduce
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "leaf")
                        .foregroundStyle(SMColor.primary)
                        .font(.caption)
                    Text("In season now")
                        .font(SMFont.label)
                        .foregroundStyle(SMColor.textTertiary)
                }
                .padding(.horizontal, SMSpacing.lg)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SMSpacing.sm) {
                        ForEach(items) { item in
                            Button {
                                pickedItem = item
                            } label: {
                                Text(item.name.capitalized)
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textPrimary)
                                    .padding(.horizontal, SMSpacing.md)
                                    .padding(.vertical, SMSpacing.sm)
                                    .background(SMColor.surfaceCard)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(SMColor.primary.opacity(item.peakScore >= 4 ? 0.6 : 0.15), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, SMSpacing.lg)
                }
            }
            .padding(.top, SMSpacing.sm)
        }
    }
}

/// Modal that appears when the user taps an in-season chip. Shows why
/// it's at peak and a "Find recipes" action that drops them in the
/// Recipes tab with the item pre-applied as a search term.
struct InSeasonDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: InSeasonItem

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: SMSpacing.sm) {
                        Text(item.name.capitalized)
                            .font(.title3.bold())
                        if !item.whyNow.isEmpty {
                            Text(item.whyNow)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        appState.selectedTab = .recipes
                        appState.recipesPrefilledSearch = item.name
                        dismiss()
                    } label: {
                        Label("Find recipes with \(item.name)", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("In season")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
        }
    }
}
