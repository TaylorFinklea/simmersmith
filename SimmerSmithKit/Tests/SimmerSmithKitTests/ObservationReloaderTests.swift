import Testing
import Foundation
import Observation
@testable import SimmerSmithKit

// simmersmith-7mb — ObservationReloader: re-register-before-reload invariant, coalescing
// drain, no-concurrent-reloads, and a bump landing mid-reload still yields a terminal reload.

/// Small `@Observable` stand-in for `session.storeRevision`.
@MainActor
@Observable
private final class RevisionSource {
    var revision: Int = 0
}

@MainActor
@Test("a single bump eventually yields exactly one reload observing the new revision")
func observationReloaderSingleBump() async {
    let source = RevisionSource()
    var reloadCount = 0
    var lastSeenRevision = -1

    let reloader = ObservationReloader(
        track: { _ = source.revision },
        reload: {
            reloadCount += 1
            lastSeenRevision = source.revision
        }
    )
    reloader.start()

    source.revision = 1

    let deadline = Date().addingTimeInterval(2)
    while reloadCount == 0 && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    #expect(reloadCount == 1)
    #expect(lastSeenRevision == 1)
}

@MainActor
@Test("a burst of synchronous bumps coalesces to a terminal reload observing the final revision")
func observationReloaderBurstCoalesces() async {
    let source = RevisionSource()
    var reloadCount = 0
    var lastSeenRevision = -1

    let reloader = ObservationReloader(
        track: { _ = source.revision },
        reload: {
            reloadCount += 1
            lastSeenRevision = source.revision
        }
    )
    reloader.start()

    let bumpCount = 5
    for i in 1...bumpCount {
        source.revision = i
    }

    // Poll until the terminal reload has observed the final bumped revision.
    let deadline = Date().addingTimeInterval(2)
    while lastSeenRevision != bumpCount && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    #expect(lastSeenRevision == bumpCount)
    #expect(reloadCount >= 1)
    #expect(reloadCount <= bumpCount)
}

@MainActor
@Test("a bump landing during an in-flight async reload triggers a second, later reload")
func observationReloaderBumpDuringReloadTriggersSecondReload() async {
    let source = RevisionSource()
    var reloadRevisions: [Int] = []
    var firstReloadStarted = false
    var releaseFirstReload: (() -> Void)?

    let reloader = ObservationReloader(
        track: { _ = source.revision },
        reload: {
            let revisionAtStart = source.revision
            if reloadRevisions.isEmpty {
                // First reload: suspend here so the test can bump mid-flight — this is
                // exactly the stale-UI window simmersmith-7mb fixes (re-register happens
                // BEFORE this suspension point, in `fire()`, so the bump below is captured).
                firstReloadStarted = true
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseFirstReload = { continuation.resume() }
                }
            }
            reloadRevisions.append(revisionAtStart)
        }
    )
    reloader.start()

    source.revision = 1

    let startDeadline = Date().addingTimeInterval(2)
    while !firstReloadStarted && Date() < startDeadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(firstReloadStarted)

    // Bump again WHILE the first reload is suspended mid-flight.
    source.revision = 2

    // Give the observation a moment to re-register + fire before releasing the first reload.
    try? await Task.sleep(nanoseconds: 20_000_000)

    releaseFirstReload?()

    let deadline = Date().addingTimeInterval(2)
    while reloadRevisions.count < 2 && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    #expect(reloadRevisions.count >= 2)
    #expect(reloadRevisions.last == 2)
}

@MainActor
@Test("releasing the reloader stops the chain (weak-self) — no reload fires after release")
func observationReloaderReleaseStopsChain() async {
    let source = RevisionSource()
    var reloadCount = 0

    var reloader: ObservationReloader? = ObservationReloader(
        track: { _ = source.revision },
        reload: { reloadCount += 1 }
    )
    reloader?.start()

    source.revision = 1

    let deadline = Date().addingTimeInterval(2)
    while reloadCount == 0 && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(reloadCount == 1)

    // Release the only strong reference to the reloader.
    reloader = nil

    // Let any in-flight work settle.
    try? await Task.sleep(nanoseconds: 50_000_000)
    let countAfterRelease = reloadCount

    // Bump again after release — the weak-self chain inside the reloader must prevent
    // any further reload from firing.
    source.revision = 2
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(reloadCount == countAfterRelease)
}
