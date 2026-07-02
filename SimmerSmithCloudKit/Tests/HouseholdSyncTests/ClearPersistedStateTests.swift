#if canImport(CloudKit)
import Foundation
import Testing
@testable import HouseholdSync

// simmersmith-r8q — interim fix for the stale-token/fresh-store mismatch: HouseholdSession
// rebuilds the local store fresh in-memory every launch while the CKSyncEngine state token
// persists on disk, so a resumed `fetchChanges` silently returns only deltas against a store
// that never had the base data. `clearPersistedState` deletes that on-disk token so the next
// engine construction starts from nil and does a full zone re-fetch. A live CKSyncEngine.State
// .Serialization can't easily be constructed in a unit test, so these tests exercise the
// helper's actual contract — file deletion — directly, same convention as ShareRecordFilterTests.

@Test("clearPersistedState deletes an existing state file")
func clearPersistedStateDeletesExistingFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("simmersmith-r8q-\(UUID().uuidString).json")
    try Data("arbitrary state bytes".utf8).write(to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))

    HouseholdSyncEngine.clearPersistedState(at: url)

    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test("clearPersistedState on a nonexistent file does not throw or crash")
func clearPersistedStateNonexistentFileIsNoop() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("simmersmith-r8q-missing-\(UUID().uuidString).json")
    #expect(!FileManager.default.fileExists(atPath: url.path))

    HouseholdSyncEngine.clearPersistedState(at: url)

    #expect(!FileManager.default.fileExists(atPath: url.path))
}
#endif
