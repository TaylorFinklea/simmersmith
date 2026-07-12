import SwiftUI
import UniformTypeIdentifiers

/// A backup's JSON wrapped for SwiftUI `.fileExporter` (reliable "Save to Files" — sharing an
/// Application-Support file URL directly via ShareLink doesn't reliably reach the Files app).
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// SP-C backup/restore — the "Backups" Settings section. Lists on-device snapshots (auto-rolling
/// + manual), restores one (recover = additive, never destructive), and exports/imports to Files.
struct BackupRestoreSection: View {
    @Environment(AppState.self) private var appState

    @State private var backups: [AppState.BackupFile] = []
    @State private var pendingRestore: AppState.BackupFile?
    @State private var working = false
    @State private var status: String?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDoc: BackupDocument?
    @State private var exportName = "backup"

    var body: some View {
        Section {
            Button {
                if appState.writeSnapshot(manual: true) != nil { status = "Backed up." }
                else { status = appState.lastErrorMessage ?? "Couldn't create the backup." }
                reload()
            } label: {
                Label("Back up now", systemImage: "arrow.down.doc")
            }
            .disabled(working)

            if backups.isEmpty {
                Text("No backups yet. Your meals + recipes back up automatically once a day.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
            } else {
                ForEach(backups) { file in
                    HStack {
                        Button { pendingRestore = file } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.capturedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(SMFont.subheadline)
                                    .foregroundStyle(SMColor.textPrimary)
                                Text(Self.sizeString(file.byteSize))
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(working)

                        Button {
                            if let data = try? Data(contentsOf: file.url) {
                                exportDoc = BackupDocument(data: data)
                                exportName = file.url.deletingPathExtension().lastPathComponent
                                exporting = true
                            } else {
                                status = "Couldn't read that backup to export."
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(SMColor.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            appState.deleteBackup(file)
                            reload()
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }

            Button { importing = true } label: {
                Label("Restore from a file…", systemImage: "tray.and.arrow.down")
            }
            .disabled(working)

            if let status {
                Text(status)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            }
        } header: {
            SmithSectionHeader("backups")
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Recover from this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Recover") { if let file = pendingRestore { restore(from: file.url, label: "backup") } }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text(appState.isParticipant
                 ? "This recovers the SHARED household, so it affects everyone in it. It re-adds anything missing and overwrites changed items back to this backup — it won't delete newer changes. Memory photos aren't included in backups, so they won't come back."
                 : "Re-adds anything missing and overwrites changed items back to this backup. It won't delete newer changes. Memory photos aren't included in backups, so they won't come back.")
        }
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json, defaultFilename: exportName) { result in
            switch result {
            case .success: status = "Exported to Files."
            case .failure(let error): status = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                restore(from: url, label: "file") { if scoped { url.stopAccessingSecurityScopedResource() } }
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    private func reload() { backups = appState.listBackups() }

    private func restore(from url: URL, label: String, cleanup: @escaping () -> Void = {}) {
        working = true
        status = "Recovering…"
        pendingRestore = nil
        Task {
            defer { cleanup() }
            do {
                try await appState.restoreHousehold(fromFile: url)
                status = "Recovered from this \(label)."
            } catch {
                status = "Couldn't restore: \(error.localizedDescription)"
            }
            working = false
            reload()
        }
    }

    private static func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
