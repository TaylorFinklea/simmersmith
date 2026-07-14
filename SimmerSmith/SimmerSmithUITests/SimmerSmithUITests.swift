import XCTest

/// The launch smoke test.
///
/// This suite used to drive the pre-CloudKit Fly connection form — a server-URL text field, a
/// "Bearer token" secure field, a "Save and Connect" button. None of that UI has existed since
/// the CloudKit-only cut-over, so six of its seven tests failed on every single run, and the
/// seventh "passed" only because it asserted nothing:
///
///     let tabBar = app.tabBars.firstMatch
///     if tabBar.exists { XCTAssertTrue(...) }   // tab bar absent → no assertion runs
///
/// A permanently-red suite is worse than no suite: `** TEST FAILED **` stops meaning anything,
/// and a real regression hides in the noise. A test that cannot fail is worse still.
///
/// What replaces them asserts the one thing that holds on ANY machine — that launch settles.
final class SimmerSmithUITests: XCTestCase {
    /// Launch must reach a terminal gate.
    ///
    /// WHICH gate depends on the machine's iCloud account, and both are correct landings: signed
    /// in, the household resolves and the kitchen opens (tab bar); signed out, `RootView` shows
    /// the "Sign in to iCloud" prompt. Accepting either is what keeps this stable on a dev Mac
    /// and on a signed-out CI runner alike — the old suite's real problem was asserting on one
    /// specific screen that stopped existing.
    ///
    /// What launch must NEVER do is sit on "Opening your kitchen…" forever. That is the hang
    /// `RootView` calls out as finding F3: a transient (non-auth) CloudKit failure leaves
    /// `householdLaunchPhase == .resolving`, and the spinner spins with no way out. This is the
    /// regression guard for it — and because neither gate appears if the app crashes on launch
    /// or renders an empty `RootView`, those come free.
    func testLaunchSettlesOnATerminalGateAndNeverHangsOnTheSpinner() {
        let app = XCUIApplication()
        app.launch()

        let kitchen = app.tabBars.firstMatch
        let iCloudGate = app.staticTexts["Sign in to iCloud"]
        let spinner = app.staticTexts["Opening your kitchen…"]

        // Either gate ends the launch. XCTest has no built-in "wait for any of these", so the
        // OR lives in the predicate rather than in two expectations (which would wait for BOTH).
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in kitchen.exists || iCloudGate.exists },
            object: nil)
        settled.expectationDescription = "launch reaches the kitchen or the iCloud gate"

        // Generous: a signed-in machine pays for CloudKit discovery, including the zero-zone
        // retry backoffs (~1.5s + ~3s) before the household resolves.
        guard XCTWaiter.wait(for: [settled], timeout: 30) == .completed else {
            // Say WHICH failure this is — the two mean very different things.
            XCTFail(spinner.exists
                ? "Launch hung on the spinner: RootView never left .resolving (finding F3 — a "
                    + "transient CloudKit failure with no way out)."
                : "Launch reached neither gate and isn't even loading: RootView rendered nothing, "
                    + "or the app crashed on launch.")
            return
        }

        // Redundant by construction — RootView's switch renders exactly one of the three states,
        // so settling means the spinner is gone. Kept because it names the invariant the wait
        // above is really enforcing, and it would catch the switch growing a state that renders
        // a gate and the spinner together.
        XCTAssertFalse(spinner.exists, "Settled on a gate but the loading spinner is still up.")
    }
}
