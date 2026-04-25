import SwiftUI
import SimmerSmithKit

/// Edits an existing event's metadata (name, date, occasion,
/// attendee_count, notes, status). Guests stay in AttendeePickerSheet
/// — we don't duplicate that flow here.
struct EventEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let event: Event

    @State private var name: String = ""
    @State private var eventDate: Date = .now
    @State private var hasDate: Bool = false
    @State private var occasion: String = "other"
    @State private var attendeeCount: Int = 1
    @State private var notes: String = ""
    @State private var status: String = "draft"
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let occasions = [
        "dinner party", "holiday", "birthday", "anniversary",
        "brunch", "picnic", "other",
    ]
    private let statuses = ["draft", "confirmed", "complete"]

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
                    Stepper(value: $attendeeCount, in: 1...500) {
                        Text("Attendees: \(attendeeCount)")
                    }
                    Picker("Status", selection: $status) {
                        ForEach(statuses, id: \.self) { s in
                            Text(s.capitalized).tag(s)
                        }
                    }
                }

                Section("Notes") {
                    TextField(
                        "Anything the AI should know?",
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .onAppear(perform: seed)
        }
    }

    private func seed() {
        name = event.name
        occasion = event.occasion
        attendeeCount = event.attendeeCount
        notes = event.notes
        status = event.status
        if let d = event.eventDate {
            eventDate = d
            hasDate = true
        } else {
            hasDate = false
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            // Keep attendees unchanged — those are edited in the
            // AttendeePickerSheet. Pass the current list through to
            // avoid a wholesale wipe on the backend's PATCH path.
            let currentAttendees = event.attendees.map {
                (guestID: $0.guestId, plusOnes: $0.plusOnes)
            }
            _ = try await appState.updateEvent(
                eventID: event.eventId,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                eventDate: hasDate ? eventDate : nil,
                occasion: occasion,
                attendeeCount: attendeeCount,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                status: status,
                attendees: currentAttendees
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
