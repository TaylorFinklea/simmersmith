import SwiftUI
import SimmerSmithKit

/// Inline guest create/edit sheet — used inside the event create flow
/// and from the Settings → Guests list (Phase 5).
struct GuestEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let guest: Guest?
    var onSaved: (Guest) -> Void = { _ in }

    @State private var name: String = ""
    @State private var relationshipLabel: String = ""
    @State private var allergies: String = ""
    @State private var dietaryNotes: String = ""
    @State private var ageGroup: String = "adult"
    @State private var active: Bool = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let ageGroups: [(key: String, label: String)] = [
        ("baby", "Baby (<1y)"),
        ("toddler", "Toddler (1-3)"),
        ("child", "Child (4-12)"),
        ("teen", "Teen (13-17)"),
        ("adult", "Adult"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Who is it?") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Relationship (optional, e.g. \"Aunt\")", text: $relationshipLabel)
                        .textInputAutocapitalization(.words)
                    Picker("Age group", selection: $ageGroup) {
                        ForEach(ageGroups, id: \.key) { group in
                            Text(group.label).tag(group.key)
                        }
                    }
                }
                Section {
                    TextField("e.g. gluten, shellfish", text: $allergies)
                } header: {
                    Text("Allergies")
                } footer: {
                    Text("The AI will treat anything listed here as a hard constraint — it will never propose meals that contain these.")
                }
                Section {
                    TextField("e.g. \"no mushrooms, loves spicy\"", text: $dietaryNotes, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Preferences / notes")
                } footer: {
                    Text("Softer guidance the AI should respect when possible.")
                }
                Section {
                    Toggle("Active", isOn: $active)
                } footer: {
                    Text("Inactive guests are hidden from event attendee pickers but kept for history.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle(guest == nil ? "New guest" : "Edit guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .foregroundStyle(SMColor.ember)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .smithToolbar()
            .onAppear {
                if let guest {
                    name = guest.name
                    relationshipLabel = guest.relationshipLabel
                    allergies = guest.allergies
                    dietaryNotes = guest.dietaryNotes
                    ageGroup = guest.ageGroup
                    active = guest.active
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            let updated = try await appState.upsertGuest(
                guestID: guest?.guestId,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                relationshipLabel: relationshipLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                dietaryNotes: dietaryNotes.trimmingCharacters(in: .whitespacesAndNewlines),
                allergies: allergies.trimmingCharacters(in: .whitespacesAndNewlines),
                ageGroup: ageGroup,
                active: active
            )
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
