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
    @State private var selectedGuestIDs: Set<String> = []
    @State private var showingGuestEditor = false
    @State private var isSaving = false
    @State private var errorMessage: String?

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
                    Stepper(value: $attendeeCount, in: 1...200) {
                        Text("Attendees: \(attendeeCount)")
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
                        Button {
                            toggle(guest)
                        } label: {
                            HStack {
                                Image(systemName: selectedGuestIDs.contains(guest.guestId)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .foregroundStyle(selectedGuestIDs.contains(guest.guestId) ? SMColor.primary : SMColor.textTertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(guest.name)
                                        .foregroundStyle(SMColor.textPrimary)
                                    if !guest.allergies.isEmpty {
                                        Text("Allergies: \(guest.allergies)")
                                            .font(SMFont.caption)
                                            .foregroundStyle(Color.red)
                                    } else if !guest.dietaryNotes.isEmpty {
                                        Text(guest.dietaryNotes)
                                            .font(SMFont.caption)
                                            .foregroundStyle(SMColor.textSecondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        showingGuestEditor = true
                    } label: {
                        Label("Add guest with dietary notes", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Guests with dietary constraints")
                } footer: {
                    Text("Pick any attendees whose allergies or preferences the AI should design around. The AI sees their names + notes when building the menu.")
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
                    selectedGuestIDs.insert(created.guestId)
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
        if selectedGuestIDs.contains(guest.guestId) {
            selectedGuestIDs.remove(guest.guestId)
        } else {
            selectedGuestIDs.insert(guest.guestId)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let attendees = selectedGuestIDs.map { (guestID: $0, plusOnes: 0) }
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
