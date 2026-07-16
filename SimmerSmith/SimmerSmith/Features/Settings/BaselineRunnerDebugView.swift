import SwiftUI
import UniformTypeIdentifiers

/// Debug-only panel that runs the P8 production-cloud baseline sweep (spec §D3) on this device's
/// real configured provider/Keychain. Reachable from Settings → Developer, same `DebugGate` gate
/// and Settings embedding as `CloudKitDebugView` — ships dormant in Release exactly like it. All
/// sweep mechanics live in the testable `BaselineRunnerController`; this view is thin UI wiring.
struct BaselineRunnerDebugView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: BaselineRunnerController?

    @State private var exportingMetrics = false
    @State private var exportingProvenance = false
    @State private var metricsDoc: BackupDocument?
    @State private var provenanceDoc: BackupDocument?
    @State private var exportStatus: String?

    var body: some View {
        Form {
            if let controller {
                content(for: controller)
            } else {
                Section { ProgressView() }
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Baseline sweep")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let runner = controller ?? BaselineRunnerController.live(appState: appState) { metrics, provenance in
                metricsDoc = BackupDocument(data: metrics)
                provenanceDoc = BackupDocument(data: provenance)
                exportStatus = nil
                exportingMetrics = true
            }
            controller = runner
            runner.prepare()
        }
        .onDisappear {
            guard let controller else { return }
            Task { await controller.cancel() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active, let controller else { return }
            Task { await controller.cancel() }
        }
        // Sequential single-document exports (BackupRestoreSection's pattern) — the provenance
        // sidecar's SHA-256 binds the pair regardless of export order (spec §D3 step 4).
        .fileExporter(
            isPresented: $exportingMetrics, document: metricsDoc, contentType: .json,
            defaultFilename: "voice-baseline-metrics"
        ) { result in
            switch result {
            case .success: exportStatus = "Metrics exported."
            case .failure(let error): exportStatus = "Metrics export failed: \(error.localizedDescription)"
            }
            exportingProvenance = true
        }
        .fileExporter(
            isPresented: $exportingProvenance, document: provenanceDoc, contentType: .json,
            defaultFilename: "voice-baseline-provenance"
        ) { result in
            switch result {
            case .success: exportStatus = (exportStatus ?? "") + " Provenance exported."
            case .failure(let error):
                exportStatus = (exportStatus ?? "") + " Provenance export failed: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func content(for controller: BaselineRunnerController) -> some View {
        switch controller.state {
        case .idle:
            Section { ProgressView("Loading…") }

        case .consentUnavailable(let message):
            Section {
                Text(message)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                Button("Retry") { controller.prepare() }
            } header: {
                SmithSectionHeader("baseline sweep")
            }

        case .awaitingConsent(let info):
            Section {
                LabeledContent("Provider", value: info.identity.providerName)
                LabeledContent("Model", value: info.identity.modelIdentifier)
                LabeledContent("Live calls", value: "\(info.totalCalls) (\(info.caseCount) × \(info.runsPerCase))")
                Text("This spends your own API key on \(info.totalCalls) live calls against the frozen golden corpus. Nothing is charged to SimmerSmith.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
                Button("Start sweep") { controller.startSweep() }
            } header: {
                SmithSectionHeader("confirm before spending")
            }

        case .running(let progress):
            Section {
                ProgressView(value: Double(progress.completedCalls), total: Double(max(progress.totalCalls, 1)))
                Text("\(progress.completedCalls) / \(progress.totalCalls) calls")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
                Button("Cancel", role: .destructive) {
                    Task { await controller.cancel() }
                }
            } header: {
                SmithSectionHeader("running")
            }

        case .aborted(let reason):
            Section {
                Text(reason)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                Button("Reset") { controller.reset(); controller.prepare() }
            } header: {
                SmithSectionHeader("aborted — no artifact")
            }

        case .completed(let run):
            Section {
                LabeledContent("entryF1", value: String(format: "%.3f", run.metrics.entryF1))
                LabeledContent("exactPlanMatchRate", value: String(format: "%.3f", run.metrics.exactPlanMatchRate))
                LabeledContent("fallbackRate", value: String(format: "%.3f", run.metrics.fallbackRate))
                LabeledContent("meanLatencyMilliseconds", value: String(format: "%.0f", run.metrics.meanLatencyMilliseconds))
                Button("Export both files…") { controller.exportNow() }
                if let exportStatus {
                    Text(exportStatus)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }
            } header: {
                SmithSectionHeader("complete — 180/180")
            }
        }
    }
}
