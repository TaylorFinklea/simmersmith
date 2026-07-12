import CloudKit
import Foundation
import HouseholdSync
import Testing

@testable import SimmerSmith

/// Bead simmersmith-zgt — a memory photo's CKAsset can land AFTER the row first
/// renders (participant device; the record syncs before its file downloads).
/// `memoryPhotoBytes` returns nil then, and the `ckmem:<id>` cacheBuster is
/// deterministic, so nothing re-fired the fetch: the placeholder stuck until
/// view teardown. The fix keys view retries off `RecipeRepository.storeGeneration`,
/// bumped by every `reload()` (which the revisionReloader runs on each
/// household-store change). These tests pin that signal end-to-end on the real
/// session/store/codec stack.
@MainActor
struct RecipeMemoryLiveUpdateTests {
    @Test
    func storeGenerationBumpsOnEveryReload() {
        let session = HouseholdSession(householdID: "zgt-gen-\(UUID().uuidString)")
        let repo = RecipeRepository(session: session)

        let before = repo.storeGeneration
        repo.reload()
        repo.reload()

        #expect(repo.storeGeneration == before + 2)
    }

    /// The production trigger chain, not just explicit CRUD: a remote batch bumps
    /// `session.storeRevision`; the repo's revisionReloader observes it and runs
    /// `reload()`, which bumps `storeGeneration`. A regression here (startObserving
    /// never called, track/reload mis-wired) is invisible to the CRUD-driven tests.
    @Test
    func remoteStoreRevisionBumpPropagatesToStoreGeneration() async throws {
        let session = HouseholdSession(householdID: "zgt-chain-\(UUID().uuidString)")
        let repo = RecipeRepository(session: session)
        repo.startObserving()

        let before = repo.storeGeneration
        session.storeRevision += 1

        // Observation delivery is async; poll briefly like ObservationReloaderTests.
        for _ in 0..<200 where repo.storeGeneration == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(repo.storeGeneration > before)
    }

    @Test
    func photoBytesRecoverAfterLateAssetArrivalAndGenerationSignalsIt() async throws {
        let session = HouseholdSession(householdID: "zgt-photo-\(UUID().uuidString)")
        let repo = RecipeRepository(session: session)

        let memoryID = repo.addMemory("zgt-recipe-\(UUID().uuidString)", body: "asset races the record")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array("zgt-late-asset".utf8))
        repo.setMemoryPhoto(memoryID, jpeg, mime: "image/jpeg")

        // Simulate the participant-device gap: the RecipeMemoryImage record is in
        // the store, but its asset bytes are unreadable. (Deleting the staged file
        // makes decode throw on the read — a different error case than
        // assetNotDownloaded, but memoryPhotoBytes swallows both into the same
        // nil the views see.)
        let imageID = CKRecord.ID(
            recordName: RecipeMemoryImageCodec.recordName(forMemory: memoryID),
            zoneID: session.zoneID
        )
        let record = try #require(session.store.record(for: imageID))
        let assetURL = try #require((record["imageAsset"] as? CKAsset)?.fileURL)
        try FileManager.default.removeItem(at: assetURL)

        let whileMissing = await repo.memoryPhotoBytes(memoryID)
        #expect(whileMissing == nil)
        let generationWhileMissing = repo.storeGeneration

        // The asset "arrives": re-staging writes the file back and saves through
        // the engine, which reloads — the exact path a synced-in record takes.
        repo.setMemoryPhoto(memoryID, jpeg, mime: "image/jpeg")

        #expect(repo.storeGeneration > generationWhileMissing)
        let recovered = await repo.memoryPhotoBytes(memoryID)
        #expect(recovered == jpeg)
    }
}
