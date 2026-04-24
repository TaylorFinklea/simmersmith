import SwiftUI
import SimmerSmithKit

/// Sheet for creating a new event with name, date, occasion, attendee
/// count, optional notes, and a guest picker. Guests are reusable: pick
/// existing ones or add a new inline "+ Add guest" entry.
struct EventCreateSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var onCreated: (Event) -> Void

    @State private var name: String = ""
    @State private var eventDate: Date = .now
    @State private var hasDate: Bool = true
    @State private var occasion: String = "dinner party"
    @State private var attendeeCount: Int = 4
    @State private var notes: String = ""
    /// Map of guest_id → plus_ones. Empty means "no named guest list,
    /// use attendeeCount as the manual headcount override."
    @State private var selectedGuests: [String: Int] = [:]
    @State private var showingGuestEditor = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Set to true the moment the user types in the attendee stepper
    /// directly, so the derived-from-guests count stops overwriting
    /// their manual value.
    @State private var attendeeCountManuallyOverridden = false

    private let occasions = [
        "dinner party", "holiday", "birthday", "anniversary",
        "brunch", "picnic", "other",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Event name", text: $name)
                    Toggle("Has a date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Date", selection: $eventDate, displayedComponents: .date)
                    }
                    Picker("Occasion", selection: $occasion) {
                        ForEach(occasions, id: \.self) { occ in
                            Text(occ.capitalized).tag(occ)
                        }
                    }
                    Stepper(value: Binding(
                        get: { attendeeCount },
                        set: { newValue in
                            attendeeCount = newValue
                            attendeeCountManuallyOverridden = true
                        }
                    ), in: 1...500) {
                        Text("Attendees: \(attendeeCount)")
                    }
                    if !selectedGuests.isEmpty && !attendeeCountManuallyOverridden {
                        Text("Auto-matched to your guest list — tap the stepper to override.")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    }
                }

                Section("Notes") {
                    TextField(
                        "Anything the AI should know? (e.g. \"traditional ham dinner\")",
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                Section {
                    ForEach(appState.guests.filter { $0.active }) { guest in
                        guestRow(for: guest)
                    }
                    Button {
                        showingGuestEditor = true
                    } label: {
                        Label("Add a new guest", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Guest list")
                } footer: {
                    Text("Check anyone attending. The AI uses guests' saved allergies + notes when designing the menu; leave those blank for guests without constraints. Plus-ones let one entry cover a family.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Create") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showingGuestEditor) {
                GuestEditorSheet(guest: nil) { created in
                    selectedGuests[created.guestId] = 0
                    recomputeDerivedCount()
                }
            }
            .task {
                if appState.guests.isEmpty {
                    await appState.refreshGuests()
                }
            }
        }
    }

    private func toggle(_ guest: Guest) {
        if selectedGuests.removeValue(forKey: guest.guestId) != nil {
            recomputeDerivedCount()
            return
        }
        selectedGuests[guest.guestId] = 0
        recomputeDerivedCount()
    }

    private func setPlusOnes(_ guest: Guest, _ value: Int) {
        selectedGuests[guest.guestId] = max(0, value)
        recomputeDerivedCount()
    }

    /// Update the derived attendeeCount from the guest list unless the
    /// user has typed a number manually.
    private func recomputeDerivedCount() {
        guard !attendeeCountManuallyOverridden else { return }
        let derived = selectedGuests.values.reduce(0) { $0 + 1 + $1 }
        if derived > 0 {
            attendeeCount = derived
        }
    }

    @ViewBuilder
    private func guestRow(for guest: Guest) -> some View {
        let isSelected = selectedGuests[guest.guestId] != nil
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            Button {
                toggle(guest)
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? SMColor.primary : SMColor.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(guest.name)
                            .foregroundStyle(SMColor.textPrimary)
                        constraintCaption(for: guest)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isSelected {
                Stepper(
                    value: Binding(
                        get: { selectedGuests[guest.guestId] ?? 0 },
                        set: { setPlusOnes(guest, $0) }
                    ),
                    in: 0...20
                ) {
                    Text("Plus-ones: \(selectedGuests[guest.guestId] ?? 0)")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }
                .padding(.leading, SMSpacing.lg)
            }
        }
    }

    @ViewBuilder
    private func constraintCaption(for guest: Guest) -> some View {
        let parts: [(String, Color)] = {
            var result: [(String, Color)] = []
            if !guest.allergies.isEmpty {
                result.append(("⚠︎ \(guest.allergies)", Color.red))
            }
            if !guest.dietaryNotes.isEmpty {
                result.append((guest.dietaryNotes, SMColor.textSecondary))
            }
            return result
        }()
        if parts.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(parts.indices, id: \.self) { idx in
                    Text(parts[idx].0)
                        .font(SMFont.caption)
                        .foregroundStyle(parts[idx].1)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let attendees: [(guestID: String, plusOnes: Int)] = selectedGuests.map {
            (guestID: $0.key, plusOnes: $0.value)
        }
        do {
            let event = try await appState.createEvent(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                eventDate: hasDate ? eventDate : nil,
                occasion: occasion,
                attendeeCount: attendeeCount,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                attendees: attendees
            )
            onCreated(event)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
