#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SimmerSmithKit
import HouseholdRecords
import HouseholdSync

// SP-C Task 3 — GuestRepository: the .guest roster CRUD backed by the CloudKit household store.
//
// Small sibling of EventRepository (kept separate per spec §2 — guests are a roster plane that
// outlives any one event). Mirrors WeekRepository/RecipeRepository: @MainActor @Observable,
// reactive on storeRevision, upsert-into-existing to preserve the server change tag, explicit
// per-record delete (NOT cascade — a guest is never a cascade parent of an event, only setNull'd
// off attendees/meals).
//
// Guest ⇄ .guest mapping is owned by EventRecordMapper (T1: EventRecordMapper.record(from:) /
// .guest(from:)); this repository just drives the store + sync.
//
// EventRepository resolves the live Guest for each attendee directly from the store during
// aggregate reassembly (so a detail load never depends on this repository's in-memory list being
// fresh) — this repository's `guests` array is the roster the editor UI binds to.

@MainActor
@Observable
final class GuestRepository {

    // MARK: - Observable state

    private(set) var guests: [Guest] = []

    /// Set when `sendUntilDrained()` fails on any write path (mirrors RecipeRepository).
    private(set) var lastSyncError: Error?

    // MARK: - Plumbing

    private let session: HouseholdSession

    // MARK: - Init

    init(session: HouseholdSession) {
        self.session = session
    }

    // MARK: - Observe storeRevision

    /// Wire the revision observer via `ObservationReloader` (simmersmith-7mb) — re-registers
    /// before each reload so a bump during an in-flight reload is never missed.
    @ObservationIgnored
    private lazy var revisionReloader = ObservationReloader(
        track: { [weak self] in _ = self?.session.storeRevision },
        reload: { [weak self] in self?.reload() }
    )

    func startObserving() {
        revisionReloader.start()
    }

    // MARK: - Read

    /// Recompute `guests` from the local store, name-sorted (case-insensitive) to match the
    /// server roster ordering AppState applies after every upsert.
    func reload() {
        let records = session.store.records(ofType: HouseholdRecordType.guest.recordTypeName)
        guests = records
            .map { EventRecordMapper.guest(from: HouseholdRecordCodec.decode($0, as: .guest)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look a guest up by record name. Reads the store (not the in-memory list) so an
    /// event reassembly resolves the freshest roster state.
    func guest(forId guestID: String) -> Guest? {
        guard let record = session.store.record(
            for: CKRecord.ID(recordName: guestID, zoneID: session.zoneID)) else { return nil }
        return EventRecordMapper.guest(from: HouseholdRecordCodec.decode(record, as: .guest))
    }

    // MARK: - Write

    /// Create or update a guest. New guests mint a UUID record name. Returns the upserted Guest.
    @discardableResult
    func upsertGuest(
        guestID: String? = nil,
        name: String,
        relationshipLabel: String = "",
        dietaryNotes: String = "",
        allergies: String = "",
        ageGroup: String = "adult",
        active: Bool = true
    ) -> Guest {
        let id = guestID ?? UUID().uuidString
        // Preserve the original createdAt on update; stamp a fresh one on insert.
        let existing = guest(forId: id)
        let guest = Guest(
            guestId: id,
            name: name,
            relationshipLabel: relationshipLabel,
            dietaryNotes: dietaryNotes,
            allergies: allergies,
            ageGroup: ageGroup,
            active: active,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )
        upsertRecord(EventRecordMapper.record(from: guest))
        reload()
        Task { [weak self] in await self?.drainSync() }
        return guest
    }

    /// Delete a guest. Explicit single-record delete (the .guest type is a setNull target of
    /// attendees/meals — its references null out on the peers rather than cascading).
    func deleteGuest(_ guestID: String) {
        let id = CKRecord.ID(recordName: guestID, zoneID: session.zoneID)
        guard session.store.record(for: id) != nil else { return }
        session.engine.delete(id)
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    // MARK: - Write helpers (mirror WeekRepository.upsertRecord)

    private func upsertRecord(_ value: HouseholdRecordValue) {
        let id = CKRecord.ID(recordName: value.recordName, zoneID: session.zoneID)
        if let existing = session.store.record(for: id) {
            let fieldTypes = Dictionary(uniqueKeysWithValues: value.type.fields.map { ($0.name, $0.type) })
            for (name, scalar) in value.scalars {
                guard fieldTypes[name] != nil else { continue }
                existing[name] = ckValue(for: scalar)
            }
            session.engine.save(existing)
        } else {
            session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
        }
    }

    private func ckValue(for scalar: ScalarValue) -> CKRecordValue {
        switch scalar {
        case .string(let v): return v as CKRecordValue
        case .int(let v):    return v as CKRecordValue
        case .double(let v): return v as CKRecordValue
        case .date(let v):   return v as CKRecordValue
        case .bool(let v):   return (v ? 1 : 0) as CKRecordValue
        }
    }

    private func drainSync() async {
        do {
            try await session.engine.sendUntilDrained()
            lastSyncError = nil
        } catch {
            print("[GuestRepository] sendUntilDrained failed: \(error)")
            lastSyncError = error
        }
    }
}
#endif
