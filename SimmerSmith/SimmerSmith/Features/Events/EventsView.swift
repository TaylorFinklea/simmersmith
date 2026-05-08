import SwiftUI
import SimmerSmithKit

/// Top-level Events tab — list of saved events, tappable into detail,
/// plus a "+ New event" entry point. Mirrors the Week tab structure.
struct EventsView: View {
    @Environment(AppState.self) private var appState
    @State private var isCreating = false
    @State private var selectedEventID: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content

                // Build 70 — configurable FAB. Default = ➕ New event.
                TabPrimaryFAB(page: .events, contextHint: "from Events", actions: [
                    .add: { isCreating = true }
                ])
            }
            .paperBackground()
            .navigationTitle("Events")
            .navigationBarTitleDisplayMode(.inline)
            // Build 70 — top bar holds existing + button + ✨ sparkle.
            // Build 71 — hide whichever item is already the FAB.
            .toolbar {
                if eventsPrimary != .add {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isCreating = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(SMColor.ember)
                        }
                        .accessibilityLabel("New event")
                    }
                }
                if eventsPrimary != .sparkle {
                    ToolbarItem(placement: .topBarTrailing) {
                        TopBarSparkleButton(contextHint: "from Events")
                    }
                }
            }
            .smithToolbar()
            .sheet(isPresented: $isCreating) {
                EventCreateSheet { created in
                    selectedEventID = created.eventId
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedEventID != nil },
                set: { if !$0 { selectedEventID = nil } }
            )) {
                if let id = selectedEventID {
                    EventDetailView(eventID: id)
                }
            }
            .task { await appState.refreshEvents() }
            .refreshable { await appState.refreshEvents() }
        }
    }

    private var eventsPrimary: TopBarPrimaryAction {
        _ = appState.topBarConfigRevision
        return appState.topBarPrimary(for: .events)
    }

    @ViewBuilder
    private var content: some View {
        if appState.eventSummaries.isEmpty {
            VStack(spacing: SMSpacing.md) {
                Image(systemName: "party.popper")
                    .font(.system(size: 48))
                    .foregroundStyle(SMColor.aiPurple.opacity(0.85))
                Text("Plan a big meal")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)
                Text("Birthdays, holidays, dinner parties — set attendees + dietary notes and let the AI design the menu.")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    isCreating = true
                } label: {
                    Text("Create an event")
                        .font(SMFont.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, SMSpacing.xl)
                        .padding(.vertical, SMSpacing.md)
                        .background(SMColor.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(SMSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(appState.eventSummaries) { summary in
                    Button {
                        selectedEventID = summary.eventId
                    } label: {
                        EventSummaryRow(summary: summary)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(SMColor.surfaceCard)
                }
                .onDelete { indexSet in
                    Task { await delete(at: indexSet) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func delete(at offsets: IndexSet) async {
        for index in offsets {
            let summary = appState.eventSummaries[index]
            do {
                try await appState.deleteEvent(summary)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct EventSummaryRow: View {
    let summary: EventSummary

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            HStack {
                Text(summary.name)
                    .font(SMFont.body.weight(.semibold))
                    .foregroundStyle(SMColor.textPrimary)
                Spacer()
                if let date = summary.eventDate {
                    Text(date, style: .date)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
            HStack(spacing: SMSpacing.xs) {
                Label("\(summary.attendeeCount) guests", systemImage: "person.2")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
                Text("·")
                    .foregroundStyle(SMColor.textTertiary)
                Text(summary.occasion.capitalized)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
                if summary.mealCount > 0 {
                    Text("·")
                        .foregroundStyle(SMColor.textTertiary)
                    Text("\(summary.mealCount) dishes")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
            }
        }
        .padding(.vertical, SMSpacing.xs)
    }
}
