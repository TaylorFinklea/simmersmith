import SwiftUI
import SimmerSmithKit

/// Detail view for a single event. Shows header + attendees + menu +
/// grocery. Primary actions are "Generate menu" (kicks off the AI) and
/// "Merge into this week" (Phase 6 — shown when a linkable week exists).
struct EventDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let eventID: String

    @State private var isGenerating = false
    @State private var coverageSummary: String?
    @State private var errorMessage: String?
    @State private var showingGuestPicker = false
    @State private var mealEditorContext: EventMealEditorContext?
    @State private var showingEventEditor: Bool = false
    @State private var pendingDelete: Bool = false

    private var event: Event? { appState.eventDetails[eventID] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SMSpacing.lg) {
                if let event {
                    header(for: event)
                    attendeesSection(for: event)
                    generateSection
                    menuSection(for: event)
                    guestsBringingSection(for: event)
                    if !event.groceryItems.isEmpty {
                        grocerySection(for: event)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(SMFont.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SMSpacing.md)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: SMRadius.sm))
                    }
                } else {
                    ProgressView("Loading event…")
                        .frame(maxWidth: .infinity)
                        .padding(SMSpacing.xl)
                }
            }
            .padding(SMSpacing.lg)
        }
        .background(SMColor.surface)
        .navigationTitle(event?.name ?? "Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(SMColor.surface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if event != nil {
                    Menu {
                        Button {
                            showingEventEditor = true
                        } label: {
                            Label("Edit event info", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDelete = true
                        } label: {
                            Label("Delete event", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }
            }
        }
        .task { await loadIfNeeded() }
        .refreshable { await load() }
        .sheet(item: $mealEditorContext) { context in
            EventMealEditorSheet(event: context.event, meal: context.meal)
        }
        .sheet(isPresented: $showingEventEditor) {
            if let event {
                EventEditSheet(event: event)
            }
        }
        .confirmationDialog(
            "Delete this event?",
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteEvent() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the event, its menu, and its grocery list. Merged items stay on the week until you unmerge them separately.")
        }
    }

    private func deleteEvent() async {
        guard let event else { return }
        let summary = appState.eventSummaries.first { $0.eventId == event.eventId }
            ?? EventSummary(
                eventId: event.eventId,
                name: event.name,
                eventDate: event.eventDate,
                occasion: event.occasion,
                attendeeCount: event.attendeeCount,
                status: event.status,
                linkedWeekId: event.linkedWeekId,
                mealCount: event.meals.count,
                createdAt: event.createdAt,
                updatedAt: event.updatedAt
            )
        do {
            try await appState.deleteEvent(summary)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sections

    private func header(for event: Event) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            HStack(spacing: SMSpacing.sm) {
                Image(systemName: "party.popper.fill")
                    .foregroundStyle(SMColor.aiPurple)
                Text(event.occasion.capitalized)
                    .font(SMFont.caption.weight(.semibold))
                    .foregroundStyle(SMColor.textSecondary)
                if let date = event.eventDate {
                    Text("·")
                        .foregroundStyle(SMColor.textTertiary)
                    Text(date, style: .date)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
            Text("\(event.attendeeCount) attendees")
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textPrimary)
            if !event.notes.isEmpty {
                Text(event.notes)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
                    .padding(.top, SMSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SMSpacing.md)
        .background(SMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: SMRadius.md))
    }

    private func attendeesSection(for event: Event) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            HStack {
                Text("Guests with notes")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
                Spacer()
                Button("Edit") { showingGuestPicker = true }
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.primary)
            }
            if event.attendees.isEmpty {
                Text("No specific guests listed — the AI will design for the general attendee count.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            } else {
                VStack(spacing: SMSpacing.xs) {
                    ForEach(event.attendees) { attendee in
                        HStack(alignment: .top) {
                            Text(attendee.guest.name)
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textPrimary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if !attendee.guest.allergies.isEmpty {
                                    Text("⚠︎ \(attendee.guest.allergies)")
                                        .font(SMFont.caption)
                                        .foregroundStyle(.red)
                                }
                                if !attendee.guest.dietaryNotes.isEmpty {
                                    Text(attendee.guest.dietaryNotes)
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textSecondary)
                                }
                            }
                        }
                        .padding(.vertical, SMSpacing.xs)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SMSpacing.md)
        .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md))
        .sheet(isPresented: $showingGuestPicker) {
            AttendeePickerSheet(event: event)
        }
    }

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            Button {
                Task { await generate() }
            } label: {
                HStack {
                    if isGenerating {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(event?.meals.isEmpty == false ? "Regenerate menu" : "Generate menu")
                        .font(SMFont.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SMSpacing.md)
                .background(SMColor.primary, in: RoundedRectangle(cornerRadius: SMRadius.md))
            }
            .buttonStyle(.plain)
            .disabled(isGenerating || (event?.attendeeCount ?? 0) < 1)

            if let coverage = coverageSummary, !coverage.isEmpty {
                HStack(alignment: .top, spacing: SMSpacing.xs) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(SMColor.primary)
                    Text(coverage)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }
                .padding(SMSpacing.sm)
                .background(SMColor.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: SMRadius.sm))
            }
        }
    }

    @ViewBuilder
    private func guestsBringingSection(for event: Event) -> some View {
        // "Guests bringing" — reassures the host that assigned dishes
        // are intentionally missing from their grocery list.
        let assigned = event.meals.filter { $0.assignedGuestId != nil }
        if !assigned.isEmpty {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Guests bringing")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
                ForEach(assigned) { meal in
                    HStack {
                        Image(systemName: "gift")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meal.recipeName)
                                .font(SMFont.body.weight(.semibold))
                                .foregroundStyle(SMColor.textPrimary)
                            if let name = event.attendees
                                .first(where: { $0.guestId == meal.assignedGuestId })?.guest.name {
                                Text("\(name) is bringing it — not on your shopping list")
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textSecondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(SMSpacing.sm)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: SMRadius.sm))
                }
            }
        }
    }

    private func menuSection(for event: Event) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            HStack {
                Text("Menu")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
                Spacer()
                Button {
                    mealEditorContext = EventMealEditorContext(event: event, meal: nil)
                } label: {
                    Label("Add dish", systemImage: "plus.circle")
                        .font(SMFont.caption.weight(.semibold))
                        .foregroundStyle(SMColor.primary)
                }
                .buttonStyle(.plain)
            }
            ForEach(event.meals) { meal in
                Button {
                    mealEditorContext = EventMealEditorContext(event: event, meal: meal)
                } label: {
                    EventMealCard(meal: meal, guests: event.attendees)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func grocerySection(for event: Event) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            HStack {
                Text("Grocery list (\(event.groceryItems.count))")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
                Spacer()
                Button("Refresh") {
                    Task { try? await appState.refreshEventGrocery(eventID: event.eventId) }
                }
                .font(SMFont.caption)
                .foregroundStyle(SMColor.primary)
            }
            // M22: when on, the event's ingredients automatically merge
            // into the week containing `event_date` whenever the event
            // grocery is regenerated. Off is the right choice for
            // events where guests bring food (potlucks).
            Toggle(
                "Add ingredients to week's grocery list",
                isOn: Binding(
                    get: { event.autoMergeGrocery },
                    set: { newValue in
                        Task { await appState.toggleEventAutoMerge(eventID: event.eventId, enabled: newValue) }
                    }
                )
            )
            .font(SMFont.caption)
            .toggleStyle(.switch)
            ForEach(event.groceryItems) { item in
                EventGroceryRow(item: item)
            }
            EventMergeCard(event: event)
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() async {
        if event == nil {
            await load()
        }
    }

    private func load() async {
        do {
            _ = try await appState.fetchEvent(eventID: eventID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        errorMessage = nil
        do {
            let response = try await appState.generateEventMenu(eventID: eventID)
            coverageSummary = response.coverageSummary
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Cards

struct EventMealEditorContext: Identifiable {
    let id = UUID()
    let event: Event
    let meal: EventMeal?
}

private struct EventMealCard: View {
    let meal: EventMeal
    let guests: [EventAttendee]

    private var assignee: Guest? {
        guard let id = meal.assignedGuestId else { return nil }
        return guests.first(where: { $0.guestId == id })?.guest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            HStack {
                Text(meal.role.capitalized)
                    .font(SMFont.caption.weight(.semibold))
                    .foregroundStyle(SMColor.primary)
                    .padding(.horizontal, SMSpacing.sm)
                    .padding(.vertical, 3)
                    .background(SMColor.primary.opacity(0.12), in: Capsule())
                if let assignee {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.caption2)
                        Text(assignee.name)
                            .font(SMFont.caption.weight(.semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, SMSpacing.sm)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                }
                Spacer()
                if let servings = meal.servings {
                    Text("serves \(Int(servings))")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
            }
            Text(meal.recipeName)
                .font(SMFont.body.weight(.semibold))
                .foregroundStyle(SMColor.textPrimary)
            if let assignee {
                Text("\(assignee.name) is bringing this dish")
                    .font(SMFont.caption)
                    .foregroundStyle(.orange)
            }
            if !meal.notes.isEmpty {
                Text(meal.notes)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            }
            if !meal.constraintCoverage.isEmpty {
                let names = meal.constraintCoverage
                    .compactMap { id in guests.first(where: { $0.guestId == id })?.guest.name }
                if !names.isEmpty {
                    HStack(spacing: SMSpacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Works for \(names.joined(separator: ", "))")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SMSpacing.md)
        .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md))
    }
}

private struct EventGroceryRow: View {
    let item: EventGroceryItem

    private var quantityLabel: String {
        if let qty = item.totalQuantity {
            return item.unit.isEmpty ? String(format: "%g", qty) : "\(String(format: "%g", qty)) \(item.unit)"
        }
        return item.quantityText
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.ingredientName)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                if !item.category.isEmpty {
                    Text(item.category)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
            }
            Spacer()
            Text(quantityLabel)
                .font(SMFont.body.weight(.medium))
                .foregroundStyle(SMColor.primary)
            if item.mergedIntoWeekId != nil {
                Image(systemName: "link")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, SMSpacing.xs)
    }
}

/// Phase 6 — merge the event's grocery into a week's list. Finds the
/// "current" week (first non-archived with an upcoming week_start) via
/// appState, and offers a button to merge.
private struct EventMergeCard: View {
    @Environment(AppState.self) private var appState
    let event: Event
    @State private var isMerging = false
    @State private var error: String?

    private var isMerged: Bool {
        event.linkedWeekId != nil ||
        event.groceryItems.contains { $0.mergedIntoWeekId != nil }
    }

    private var candidateWeekID: String? {
        // Prefer the user's currently-viewed week if present.
        appState.currentWeek?.weekId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            if isMerged {
                HStack(spacing: SMSpacing.xs) {
                    Image(systemName: "link")
                        .foregroundStyle(.green)
                    Text("Merged into this week's grocery list")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                    Spacer()
                    Button("Unmerge") {
                        Task { await unmerge() }
                    }
                    .font(SMFont.caption.weight(.semibold))
                    .foregroundStyle(.red)
                }
            } else if let weekID = candidateWeekID {
                Button {
                    Task { await merge(weekID: weekID) }
                } label: {
                    HStack {
                        if isMerging {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.merge")
                        }
                        Text("Merge into this week's groceries")
                            .font(SMFont.body.weight(.semibold))
                    }
                    .foregroundStyle(SMColor.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.sm)
                    .background(SMColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: SMRadius.sm))
                }
                .buttonStyle(.plain)
                .disabled(isMerging)
            } else {
                Text("Open the Week tab first to choose a target week for grocery merging.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            }
            if let error {
                Text(error).font(SMFont.caption).foregroundStyle(.red)
            }
        }
        .padding(.top, SMSpacing.sm)
    }

    private func merge(weekID: String) async {
        isMerging = true
        defer { isMerging = false }
        do {
            _ = try await appState.mergeEventGroceryIntoWeek(eventID: event.eventId, weekID: weekID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func unmerge() async {
        guard let weekID = event.linkedWeekId else { return }
        do {
            _ = try await appState.unmergeEventGroceryFromWeek(eventID: event.eventId, weekID: weekID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Lightweight picker for editing an event's attendee list after create.
private struct AttendeePickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let event: Event

    @State private var selected: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(appState.guests.filter { $0.active }) { guest in
                    Button {
                        if selected.contains(guest.guestId) {
                            selected.remove(guest.guestId)
                        } else {
                            selected.insert(guest.guestId)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(guest.guestId) ? "checkmark.circle.fill" : "circle")
                            Text(guest.name)
                            Spacer()
                        }
                        .foregroundStyle(SMColor.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Guests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear {
                selected = Set(event.attendees.map(\.guestId))
                if appState.guests.isEmpty {
                    Task { await appState.refreshGuests() }
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await appState.updateEvent(
                eventID: event.eventId,
                name: event.name,
                eventDate: event.eventDate,
                occasion: event.occasion,
                attendeeCount: event.attendeeCount,
                notes: event.notes,
                status: event.status,
                attendees: selected.map { (guestID: $0, plusOnes: 0) }
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
