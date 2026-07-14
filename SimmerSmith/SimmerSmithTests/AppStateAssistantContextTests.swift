import Foundation
import SimmerSmithKit
import Testing

@testable import SimmerSmith

// bead simmersmith-48y — `sendAssistantMessage` used to ignore `pageContext` entirely
// and the only week id `ToolRegistry` could ever resolve was `appState.currentWeek`, so
// browsing "next week" and asking the assistant to change something silently edited the
// CURRENT week instead. `resolveActiveWeekID` is the precedence AppState+Assistant now
// threads into ToolRegistry: the page the user is looking at wins, then the browsed
// week, then whatever's current.

@MainActor
@Suite
struct AppStateAssistantContextTests {

    private func makeAppState() throws -> AppState {
        let container = try makeSimmerSmithModelContainer(inMemory: true)
        let suite = "AppStateAssistantContextTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AppState(
            modelContainer: container,
            settingsStore: ConnectionSettingsStore(
                defaults: defaults,
                keychain: KeychainStore(service: suite)
            )
        )
    }

    private func week(id: String, start: Date) -> WeekSnapshot {
        WeekSnapshot(
            weekId: id, weekStart: start, weekEnd: start, status: "staging", notes: "",
            readyForAiAt: nil, approvedAt: nil, pricedAt: nil, updatedAt: start,
            stagedChangeCount: 0, feedbackCount: 0, exportCount: 0,
            meals: [], groceryItems: [], nutritionTotals: [], weeklyTotals: nil
        )
    }

    @Test("pageContext's weekId wins over both browsedWeek and currentWeek")
    func pageContextWinsOverBrowsedAndCurrent() throws {
        let appState = try makeAppState()
        appState.currentWeek = week(id: "week-current", start: Date(timeIntervalSince1970: 0))
        appState.browsedWeek = week(id: "week-browsed", start: Date(timeIntervalSince1970: 604_800))

        let pageContext = AIPageContext(pageType: "week", weekId: "week-page")
        #expect(appState.resolveActiveWeekID(pageContext: pageContext) == "week-page")
    }

    @Test("browsedWeek wins over currentWeek when pageContext carries no weekId")
    func browsedWeekWinsOverCurrentWithNoPageContextWeekId() throws {
        let appState = try makeAppState()
        appState.currentWeek = week(id: "week-current", start: Date(timeIntervalSince1970: 0))
        appState.browsedWeek = week(id: "week-browsed", start: Date(timeIntervalSince1970: 604_800))

        // A page like Settings/Recipes publishes context with no weekId.
        let pageContext = AIPageContext(pageType: "recipes", weekId: nil)
        #expect(appState.resolveActiveWeekID(pageContext: pageContext) == "week-browsed")
    }

    @Test("currentWeek is the final fallback with no pageContext and no browsedWeek")
    func currentWeekIsFinalFallback() throws {
        let appState = try makeAppState()
        appState.currentWeek = week(id: "week-current", start: Date(timeIntervalSince1970: 0))

        #expect(appState.resolveActiveWeekID(pageContext: nil) == "week-current")
    }

    @Test("nil when nothing is resolvable")
    func nilWhenNothingResolvable() throws {
        let appState = try makeAppState()
        #expect(appState.resolveActiveWeekID(pageContext: nil) == nil)
    }
}
