import SimmerSmithKit
import SwiftUI

struct AIDataSharingDisclosureSheet: View {
    let providerName: String
    let onAllow: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("SimmerSmith will send AI requests directly from this device to \(providerName). SimmerSmith does not receive or proxy those requests.")
                } header: {
                    Text("Where data goes")
                }

                Section {
                    Label("Recipes, meal plans, groceries, pantry items, and household terminology", systemImage: "fork.knife")
                    Label("Dietary goals, preferences, avoidances, and allergy flags", systemImage: "heart.text.clipboard")
                    Label("Guest names, allergies, dietary notes, and event details", systemImage: "person.2")
                    Label("Text you type or dictate and relevant assistant context", systemImage: "text.bubble")
                    Label("A photo you choose when using an AI image-analysis feature", systemImage: "photo")
                } header: {
                    Text("Data that may be included")
                } footer: {
                    Text("Only information needed for the AI feature you choose is included in a request.")
                }

                Section {
                    Text("After \(providerName) receives a request, its privacy policy and terms govern how it handles that data. Your API key remains in this device's Keychain.")
                    Link("Read SimmerSmith's Privacy Policy", destination: LegalDocumentURLs.privacy)
                } footer: {
                    Text("Cloud AI is optional. Choose Not Now to keep using SimmerSmith without sending data to \(providerName). You can allow or revoke access later in Settings.")
                }
            }
            .navigationTitle("AI Data Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Allow \(providerName)") {
                        onAllow()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
