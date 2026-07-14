import CloudKit
import HouseholdRecords
import HouseholdSync
import SimmerSmithKit
import Testing

@testable import SimmerSmith

// simmersmith-f0s: EventRepository.syncAttendees used to compute
// `delete = existingNames.subtracting(desiredNames)` with no caller-baseline — createEvent/
// updateEvent passed the UI editor's stale attendee set straight through, so a partner's
// concurrently-synced attendee add was silently deleted the next time anyone saved an
// unrelated event edit. Mirrors the simmersmith-eky fix for WeekRepository.saveWeekMeals:
// delete = (existing − desired) ∩ known — reusing WeekMealDeletePolicy.toDelete directly (the
// formula is generic Set algebra, not meal-specific). Also covers the compounding fix: every
// eventAttendee upsert used to rewrite createdAt to Date(), and the manifest carried no
// updatedAt at all (so conflicts fell into the engine's blanket local-wins rebase branch).
@MainActor
@Suite(.serialized)
struct EventRepositoryTests {

    @Test
    func updateEventPreservesAConcurrentAttendeeAddNotInTheCallersBaseline() throws {
        let session = HouseholdSession(householdID: "event-concurrent-add-\(UUID().uuidString)")
        let guests = GuestRepository(session: session)
        let repo = EventRepository(session: session, guests: guests)

        let guestA = guests.upsertGuest(name: "Alex")
        let guestB = guests.upsertGuest(name: "Bailey")

        let created = try #require(repo.createEvent(
            name: "Dinner Party",
            attendees: [(guestID: guestA.guestId, plusOnes: 0)]
        ))

        // Partner B's device syncs in a concurrent attendee add — write the `.eventAttendee`
        // record directly, mirroring what a remote fetch would deposit into the local store.
        seedAttendeeRecord(eventID: created.eventId, guestID: guestB.guestId, session: session)

        // Partner A's editor opened BEFORE guestB's add landed, so its source snapshot (and
        // therefore both its `attendees` and its `knownGuestIDs`) only ever contained guestA.
        let saved = try #require(repo.updateEvent(
            eventID: created.eventId,
            name: "Dinner Party (renamed)",
            eventDate: nil,
            occasion: "other",
            attendeeCount: 1,
            notes: "",
            status: "planning",
            attendees: [(guestID: guestA.guestId, plusOnes: 0)],
            knownGuestIDs: [guestA.guestId]
        ))

        let survivingGuestIDs = Set(saved.attendees.map(\.guestId))
        #expect(survivingGuestIDs.contains(guestB.guestId))
        #expect(survivingGuestIDs.contains(guestA.guestId))
    }

    @Test
    func updateEventStillDeletesAnAttendeeTheCallerKnewAboutAndDropped() throws {
        let session = HouseholdSession(householdID: "event-known-drop-\(UUID().uuidString)")
        let guests = GuestRepository(session: session)
        let repo = EventRepository(session: session, guests: guests)

        let guestA = guests.upsertGuest(name: "Alex")
        let guestB = guests.upsertGuest(name: "Bailey")

        let created = try #require(repo.createEvent(
            name: "Dinner Party",
            attendees: [(guestID: guestA.guestId, plusOnes: 0), (guestID: guestB.guestId, plusOnes: 0)]
        ))

        // The caller's snapshot knew about BOTH guests and intentionally dropped guestB — a
        // real removal must still take effect.
        let saved = try #require(repo.updateEvent(
            eventID: created.eventId,
            name: created.name,
            eventDate: nil,
            occasion: created.occasion,
            attendeeCount: created.attendeeCount,
            notes: created.notes,
            status: created.status,
            attendees: [(guestID: guestA.guestId, plusOnes: 0)],
            knownGuestIDs: [guestA.guestId, guestB.guestId]
        ))

        let survivingGuestIDs = Set(saved.attendees.map(\.guestId))
        #expect(survivingGuestIDs == [guestA.guestId])
    }

    @Test
    func updateEventWithoutAKnownBaselineFallsBackToThePreFixFullReplaceDelete() throws {
        // Documents the deliberate back-compat default: the UI callers (EventEditSheet,
        // EventCreateSheet, EventDetailView's AttendeePickerSheet) don't yet thread a
        // `knownGuestIDs` baseline through AppState, so omitting it must behave exactly like
        // the pre-fix code (a straight `attendees` replace) — this fix must not regress anyone
        // not yet migrated to pass a baseline.
        let session = HouseholdSession(householdID: "event-no-baseline-\(UUID().uuidString)")
        let guests = GuestRepository(session: session)
        let repo = EventRepository(session: session, guests: guests)

        let guestA = guests.upsertGuest(name: "Alex")
        let guestB = guests.upsertGuest(name: "Bailey")

        let created = try #require(repo.createEvent(
            name: "Dinner Party",
            attendees: [(guestID: guestA.guestId, plusOnes: 0), (guestID: guestB.guestId, plusOnes: 0)]
        ))

        let saved = try #require(repo.updateEvent(
            eventID: created.eventId,
            name: created.name,
            eventDate: nil,
            occasion: created.occasion,
            attendeeCount: created.attendeeCount,
            notes: created.notes,
            status: created.status,
            attendees: [(guestID: guestA.guestId, plusOnes: 0)]
        ))

        let survivingGuestIDs = Set(saved.attendees.map(\.guestId))
        #expect(survivingGuestIDs == [guestA.guestId])
    }

    @Test
    func syncAttendeesPreservesCreatedAtAndStampsUpdatedAtAcrossResaves() throws {
        let session = HouseholdSession(householdID: "event-attendee-timestamps-\(UUID().uuidString)")
        let guests = GuestRepository(session: session)
        let repo = EventRepository(session: session, guests: guests)
        let guestA = guests.upsertGuest(name: "Alex")

        let created = try #require(repo.createEvent(
            name: "Dinner Party",
            attendees: [(guestID: guestA.guestId, plusOnes: 1)]
        ))

        let recordID = CKRecord.ID(recordName: "\(created.eventId)_\(guestA.guestId)", zoneID: session.zoneID)
        let firstRecord = try #require(session.store.record(for: recordID))
        let firstCreatedAt = try #require(firstRecord["createdAt"] as? Date)
        let firstUpdatedAt = try #require(firstRecord["updatedAt"] as? Date)

        _ = repo.updateEvent(
            eventID: created.eventId,
            name: created.name,
            eventDate: nil,
            occasion: created.occasion,
            attendeeCount: created.attendeeCount,
            notes: created.notes,
            status: created.status,
            attendees: [(guestID: guestA.guestId, plusOnes: 2)],
            knownGuestIDs: [guestA.guestId]
        )

        let secondRecord = try #require(session.store.record(for: recordID))
        #expect(secondRecord["createdAt"] as? Date == firstCreatedAt)
        #expect(secondRecord["plusOnes"] as? Int == 2)
        let secondUpdatedAt = try #require(secondRecord["updatedAt"] as? Date)
        #expect(secondUpdatedAt >= firstUpdatedAt)
    }

    private func seedAttendeeRecord(eventID: String, guestID: String, session: HouseholdSession) {
        let value = HouseholdRecordValue(
            type: .eventAttendee,
            recordName: "\(eventID)_\(guestID)",
            scalars: ["plusOnes": .int(0), "createdAt": .date(Date()), "updatedAt": .date(Date())],
            refs: ["event": eventID, "guest": guestID]
        )
        session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
    }
}
