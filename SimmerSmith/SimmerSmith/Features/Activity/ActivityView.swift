import SwiftUI

struct ActivityView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.exports.isEmpty {
                ContentUnavailableView(
                    "No Export Activity",
                    systemImage: "square.and.arrow.up.on.square",
                    description: Text("Queued exports for the current week will appear here after a sync.")
                )
            } else {
                List(appState.exports) { export in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(export.exportType.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(export.status.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(export.status == "completed" ? .green : .secondary)
                        }
                        Text(export.destination.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(export.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await appState.refreshWeek()
                }
            }
        }
        .navigationTitle("Activity")
    }
}
