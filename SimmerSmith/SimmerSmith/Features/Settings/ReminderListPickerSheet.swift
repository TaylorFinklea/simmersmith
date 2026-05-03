import EventKit
import SwiftUI

/// Settings sheet that lets the user pick which Reminders list mirrors
/// the household grocery list, or create a brand-new "SimmerSmith" list
/// if none of theirs is a fit.
struct ReminderListPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var lists: [EKCalendar] = []
    @State private var newListName: String = "SimmerSmith"
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if lists.isEmpty {
                        Text("No Reminders lists available. Open Reminders.app to create one, or use the option below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lists, id: \.calendarIdentifier) { calendar in
                            ReminderListRow(calendar: calendar) {
                                Task {
                                    await appState.chooseReminderList(calendar)
                                    dismiss()
                                }
                            }
                        }
                    }
                } header: {
                    Text("Existing Lists")
                }

                Section {
                    HStack {
                        TextField("List name", text: $newListName)
                            .textInputAutocapitalization(.words)
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(isCreating || newListName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Or Create New")
                } footer: {
                    Text("A new Reminders list will be created on your iCloud account (or local if iCloud isn't available).")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Choose Reminders List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { lists = appState.availableReminderLists() }
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        let trimmed = newListName.trimmingCharacters(in: .whitespaces)
        let ok = await appState.createAndChooseReminderList(name: trimmed)
        if ok {
            dismiss()
        } else {
            errorMessage = appState.lastErrorMessage ?? "Could not create the list."
        }
    }
}

/// Single picker row. Extracted because inlining the body inside the
/// ForEach closure trips Swift's `Binding` overload resolution when
/// the closure also reads `@Observable` state from AppState.
private struct ReminderListRow: View {
    @Environment(AppState.self) private var appState
    let calendar: EKCalendar
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Circle()
                    .fill(Color(cgColor: calendar.cgColor))
                    .frame(width: 14, height: 14)
                Text(calendar.title)
                    .foregroundStyle(.primary)
                Spacer()
                if appState.reminderListIdentifier == calendar.calendarIdentifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
