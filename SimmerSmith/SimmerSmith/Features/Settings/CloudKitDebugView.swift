#if DEBUG
import SwiftUI
import CloudKitProvisioning
import CoexistenceSpike

/// Debug-only panel to run the SP-A CloudKit checks on a signed-in sim/device.
/// Reachable from Settings → Developer (DEBUG builds only). Container
/// `iCloud.app.simmersmith.cloud`. See `.docs/ai/phases/cloudkit-sp-a-spec.md`.
struct CloudKitDebugView: View {
    @State private var output = "Tap a check to run it.\nThe sim/device must be signed into iCloud."
    @State private var running = false

    var body: some View {
        Form {
            Section {
                Button("Phase 0 — HouseholdProfile round-trip") {
                    run { "round-trip name = \(try await HouseholdZoneProvisioner().verifyRoundTrip())" }
                }
                Button("Phase 0.5 — coexistence spike") {
                    runString { await CoexistenceSpike().run() }
                }
            } header: {
                SmithSectionHeader("cloudkit checks")
            } footer: {
                Text("Phase 0 proves zone + record write/read. Phase 0.5 proves NSPCKC + a CKSyncEngine-style stack coexist (→ picks Phase 1's sync mechanism).")
            }

            Section {
                Text(output)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                SmithSectionHeader("output")
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("CloudKit checks")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(running)
    }

    private func run(_ op: @escaping () async throws -> String) {
        running = true
        output = "Running…"
        Task {
            do { output = "✅ " + (try await op()) }
            catch { output = "❌ \(error)" }
            running = false
        }
    }

    private func runString(_ op: @escaping () async -> String) {
        running = true
        output = "Running…"
        Task {
            output = await op()
            running = false
        }
    }
}
#endif
