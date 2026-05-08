import SimmerSmithKit
import SwiftUI

/// Build 68 — Far-right top-bar button that opens the Smith tab with a
/// fresh thread + the current page's context attached. Lives at the
/// rightmost edge of every tab's toolbar except Week (per design).
///
/// The page-context attachment means the assistant knows where the
/// user came from (e.g. "from Forge", "from Grocery") so it can frame
/// follow-ups appropriately without the user having to re-state context.
struct TopBarSparkleButton: View {
    @Environment(AppState.self) private var appState
    @Environment(AIAssistantCoordinator.self) private var aiCoordinator

    /// Override the default page-context summary. If nil, we read
    /// whatever the page already published into `aiCoordinator.context`.
    let contextHint: String?

    init(contextHint: String? = nil) {
        self.contextHint = contextHint
    }

    var body: some View {
        Button {
            Task { await openSmith() }
        } label: {
            Image(systemName: "sparkles")
                .foregroundStyle(SMColor.ember)
        }
        .accessibilityLabel("Ask the Smith")
    }

    private func openSmith() async {
        do {
            let initialText = ""
            try await appState.beginAssistantLaunch(
                initialText: initialText,
                title: "",
                attachedRecipeID: nil,
                intent: "general"
            )
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }
}

/// Reusable wrapper that maps a `TopBarPrimaryAction` selection to the
/// concrete tap behavior the page wants. Each tab passes a closure for
/// the actions it supports; unsupported actions are no-ops (filtered
/// out by `TopBarPage.availableActions` at the model layer).
struct TopBarPrimaryButton: View {
    @Environment(AppState.self) private var appState
    let page: TopBarPage
    let actionHandlers: [TopBarPrimaryAction: () -> Void]

    var body: some View {
        let resolved = appState.topBarPrimary(for: page)
        Button {
            actionHandlers[resolved]?()
        } label: {
            Image(systemName: resolved.systemImage)
                .foregroundStyle(SMColor.ember)
        }
        .accessibilityLabel(resolved.settingsLabel)
    }
}
