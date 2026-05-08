import Foundation

extension AppState {
    /// Build 68 — UserDefaults-backed lookup. We don't keep an
    /// `@Observable` cache because the value only changes from
    /// Settings (where the picker writes through) and reads happen at
    /// view-build time, so SwiftUI re-evaluates whenever the host view
    /// re-renders for any other reason.
    func topBarPrimary(for page: TopBarPage) -> TopBarPrimaryAction {
        let key = "topBarPrimary.\(page.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let action = TopBarPrimaryAction(rawValue: raw),
           page.availableActions.contains(action) {
            return action
        }
        return page.defaultAction
    }

    /// Persist + bump `topBarConfigRevision` so any view bound to the
    /// revision re-renders. The revision is the cheap @Observable
    /// trigger; SwiftUI views read it and the actual choice via the
    /// helper above.
    func setTopBarPrimary(_ action: TopBarPrimaryAction, for page: TopBarPage) {
        let key = "topBarPrimary.\(page.rawValue)"
        UserDefaults.standard.set(action.rawValue, forKey: key)
        topBarConfigRevision &+= 1
    }
}
