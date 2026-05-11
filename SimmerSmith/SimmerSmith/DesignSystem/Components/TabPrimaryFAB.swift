import SimmerSmithKit
import SwiftUI

/// Build 70 — Floating action button mounted bottom-right of every
/// page (Week / Forge / Grocery / Pantry / Events / Smith). Reads
/// the user's per-page primary action from `AppState.topBarPrimary`
/// and dispatches to the closure the host view supplies. Sparkle is
/// handled in-place (opens Smith with page context) so callers don't
/// have to plumb the assistant launch into every tab.
struct TabPrimaryFAB: View {
    @Environment(AppState.self) private var appState

    let page: TopBarPage
    let actions: [TopBarPrimaryAction: () -> Void]
    /// Optional context hint passed to the assistant when sparkle
    /// fires. Defaults to "from <page label>".
    let contextHint: String?

    init(
        page: TopBarPage,
        contextHint: String? = nil,
        actions: [TopBarPrimaryAction: () -> Void]
    ) {
        self.page = page
        self.contextHint = contextHint
        self.actions = actions
    }

    var body: some View {
        let resolved = appState.topBarPrimary(for: page)
        Button {
            handle(resolved)
        } label: {
            Image(systemName: resolved.systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(SMColor.ember, in: Circle())
                .shadow(color: SMColor.ember.opacity(0.45), radius: 14, y: 4)
        }
        .padding(.trailing, SMSpacing.xl)
        .padding(.bottom, 16)
        .accessibilityLabel(resolved.settingsLabel)
    }

    private func handle(_ action: TopBarPrimaryAction) {
        // Sparkle: the host can override with its own handler (e.g.
        // Week presents the contextual popup sheet for the displayed
        // week instead of switching tabs). If no override is supplied,
        // fall back to the universal "open Smith with page context"
        // behavior so other pages keep working.
        if action == .sparkle {
            if let handler = actions[.sparkle] {
                handler()
            } else {
                Task { await openSmith() }
            }
            return
        }
        actions[action]?()
    }

    private func openSmith() async {
        do {
            try await appState.beginAssistantLaunch(
                initialText: "",
                title: "",
                attachedRecipeID: nil,
                intent: "general"
            )
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }
}
