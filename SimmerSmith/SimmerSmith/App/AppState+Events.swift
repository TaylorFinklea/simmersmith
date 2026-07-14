import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
#endif

extension AppState {
    // MARK: - Guests

    func refreshGuests() async {
        #if canImport(CloudKit)
        if let repo = guestRepository {
            repo.reload()
            mirrorGuestsFromRepository()
            return
        }
        #endif
        guard hasSavedConnection else { return }
        do {
            guests = try await apiClient.fetchGuests(includeInactive: true)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func upsertGuest(
        guestID: String? = nil,
        name: String,
        relationshipLabel: String = "",
        dietaryNotes: String = "",
        allergies: String = "",
        ageGroup: String = "adult",
        active: Bool = true
    ) async throws -> Guest {
        #if canImport(CloudKit)
        if let repo = guestRepository {
            let updated = repo.upsertGuest(
                guestID: guestID,
                name: name,
                relationshipLabel: relationshipLabel,
                dietaryNotes: dietaryNotes,
                allergies: allergies,
                ageGroup: ageGroup,
                active: active
            )
            mirrorGuestsFromRepository()
            return updated
        }
        #endif
        let updated = try await apiClient.upsertGuest(
            guestID: guestID,
            name: name,
            relationshipLabel: relationshipLabel,
            dietaryNotes: dietaryNotes,
            allergies: allergies,
            ageGroup: ageGroup,
            active: active
        )
        if let index = guests.firstIndex(where: { $0.guestId == updated.guestId }) {
            guests[index] = updated
        } else {
            guests.append(updated)
        }
        // Re-sort after both update and append so a rename keeps the list ordered.
        guests.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return updated
    }

    func deleteGuest(_ guest: Guest) async throws {
        #if canImport(CloudKit)
        if let repo = guestRepository {
            repo.deleteGuest(guest.guestId)
            mirrorGuestsFromRepository()
            return
        }
        #endif
        try await apiClient.deleteGuest(guestID: guest.guestId)
        guests.removeAll { $0.guestId == guest.guestId }
    }

    // MARK: - Events

    func refreshEvents() async {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            repo.reload()
            mirrorEventsFromRepository()
            return
        }
        #endif
        guard hasSavedConnection else { return }
        do {
            eventSummaries = try await apiClient.fetchEvents()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func fetchEvent(eventID: String) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            repo.reload()
            mirrorEventsFromRepository()
            if let event = repo.event(forId: eventID) {
                return event
            }
            throw NSError(
                domain: "SimmerSmith.EventRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Event not found in the local store."]
            )
        }
        #endif
        let event = try await apiClient.fetchEvent(eventID: eventID)
        eventDetails[eventID] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func createEvent(
        name: String,
        eventDate: Date? = nil,
        occasion: String = "other",
        attendeeCount: Int = 0,
        notes: String = "",
        attendees: [(guestID: String, plusOnes: Int)] = [],
        knownGuestIDs: Set<String>? = nil
    ) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            guard let event = repo.createEvent(
                name: name,
                eventDate: eventDate,
                occasion: occasion,
                attendeeCount: attendeeCount,
                notes: notes,
                attendees: attendees,
                knownGuestIDs: knownGuestIDs
            ) else {
                throw NSError(
                    domain: "SimmerSmith.EventRepository",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create event in CloudKit store."]
                )
            }
            mirrorEventsFromRepository()
            return event
        }
        #endif
        let event = try await apiClient.createEvent(
            name: name,
            eventDate: eventDate,
            occasion: occasion,
            attendeeCount: attendeeCount,
            notes: notes,
            attendees: attendees
        )
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func updateEvent(
        eventID: String,
        name: String,
        eventDate: Date?,
        occasion: String,
        attendeeCount: Int,
        notes: String,
        status: String,
        attendees: [(guestID: String, plusOnes: Int)],
        knownGuestIDs: Set<String>? = nil
    ) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            guard let event = repo.updateEvent(
                eventID: eventID,
                name: name,
                eventDate: eventDate,
                occasion: occasion,
                attendeeCount: attendeeCount,
                notes: notes,
                status: status,
                attendees: attendees,
                knownGuestIDs: knownGuestIDs
            ) else {
                throw NSError(
                    domain: "SimmerSmith.EventRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found after updateEvent."]
                )
            }
            mirrorEventsFromRepository()
            return event
        }
        #endif
        let event = try await apiClient.updateEvent(
            eventID: eventID,
            name: name,
            eventDate: eventDate,
            occasion: occasion,
            attendeeCount: attendeeCount,
            notes: notes,
            status: status,
            attendees: attendees
        )
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    func deleteEvent(_ event: EventSummary) async throws {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            repo.deleteEvent(eventID: event.eventId)
            eventSummaries.removeAll { $0.eventId == event.eventId }
            eventDetails.removeValue(forKey: event.eventId)
            return
        }
        #endif
        try await apiClient.deleteEvent(eventID: event.eventId)
        eventSummaries.removeAll { $0.eventId == event.eventId }
        eventDetails.removeValue(forKey: event.eventId)
    }

    @discardableResult
    func addEventMeal(
        eventID: String,
        role: String,
        recipeName: String,
        recipeID: String? = nil,
        servings: Double? = nil,
        notes: String = "",
        assignedGuestID: String? = nil
    ) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            guard let event = repo.addEventMeal(
                eventID: eventID,
                role: role,
                recipeName: recipeName,
                recipeID: recipeID,
                servings: servings,
                notes: notes,
                assignedGuestID: assignedGuestID
            ) else {
                throw NSError(
                    domain: "SimmerSmith.EventRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found after addEventMeal."]
                )
            }
            mirrorEventsFromRepository()
            return event
        }
        #endif
        let event = try await apiClient.addEventMeal(
            eventID: eventID,
            role: role,
            recipeName: recipeName,
            recipeID: recipeID,
            servings: servings,
            notes: notes,
            assignedGuestID: assignedGuestID
        )
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func updateEventMeal(
        eventID: String,
        mealID: String,
        role: String? = nil,
        recipeID: String? = nil,
        recipeName: String? = nil,
        servings: Double? = nil,
        notes: String? = nil,
        assignedGuestID: String? = nil,
        clearAssignee: Bool = false
    ) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            guard let event = repo.updateEventMeal(
                eventID: eventID,
                mealID: mealID,
                role: role,
                recipeID: recipeID,
                recipeName: recipeName,
                servings: servings,
                notes: notes,
                assignedGuestID: assignedGuestID,
                clearAssignee: clearAssignee
            ) else {
                throw NSError(
                    domain: "SimmerSmith.EventRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found after updateEventMeal."]
                )
            }
            mirrorEventsFromRepository()
            return event
        }
        #endif
        let event = try await apiClient.updateEventMeal(
            eventID: eventID,
            mealID: mealID,
            role: role,
            recipeID: recipeID,
            recipeName: recipeName,
            servings: servings,
            notes: notes,
            assignedGuestID: assignedGuestID,
            clearAssignee: clearAssignee
        )
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func deleteEventMeal(eventID: String, mealID: String) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            guard let event = repo.deleteEventMeal(eventID: eventID, mealID: mealID) else {
                throw NSError(
                    domain: "SimmerSmith.EventRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found after deleteEventMeal."]
                )
            }
            mirrorEventsFromRepository()
            return event
        }
        #endif
        let event = try await apiClient.deleteEventMeal(eventID: eventID, mealID: mealID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    /// M28 phase 2 — pantry supplements. DEFERRED (Pantry slice). Methods left dormant;
    /// callers should not be reached in this build (supplement UI is hidden in EventDetailView).
    @discardableResult
    func addEventSupplement(
        eventID: String,
        pantryItemID: String,
        quantity: Double,
        unit: String = "",
        notes: String = ""
    ) async throws -> Event {
        // DEFER: depends on the Pantry slice (slice 5). Supplement UI is hidden — but guard so
        // a stray call in CloudKit-only mode never silently hits Fly.
        if isCloudKitOnly {
            throw NSError(
                domain: "SimmerSmith.EventRepository",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Pantry supplements are coming soon."]
            )
        }
        let event = try await apiClient.addEventSupplement(
            eventID: eventID,
            body: SimmerSmithAPIClient.EventSupplementAddBody(
                pantryItemId: pantryItemID,
                quantity: quantity,
                unit: unit,
                notes: notes
            )
        )
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func patchEventSupplement(
        eventID: String,
        supplementID: String,
        body: SimmerSmithAPIClient.EventSupplementPatchBody
    ) async throws -> Event {
        // DEFER: depends on the Pantry slice (slice 5). Supplement UI is hidden — but guard so
        // a stray call in CloudKit-only mode never silently hits Fly.
        if isCloudKitOnly {
            throw NSError(
                domain: "SimmerSmith.EventRepository",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Pantry supplements are coming soon."]
            )
        }
        let event = try await apiClient.patchEventSupplement(
            eventID: eventID,
            supplementID: supplementID,
            body: body
        )
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func deleteEventSupplement(eventID: String, supplementID: String) async throws -> Event {
        // DEFER: depends on the Pantry slice (slice 5). Supplement UI is hidden — but guard so
        // a stray call in CloudKit-only mode never silently hits Fly.
        if isCloudKitOnly {
            throw NSError(
                domain: "SimmerSmith.EventRepository",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Pantry supplements are coming soon."]
            )
        }
        let event = try await apiClient.deleteEventSupplement(eventID: eventID, supplementID: supplementID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }


    @discardableResult
    func refreshEventGrocery(eventID: String) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            repo.refreshEventGrocery(eventID: eventID)
            mirrorEventsFromRepository()
            if let event = repo.event(forId: eventID) {
                return event
            }
            throw NSError(
                domain: "SimmerSmith.EventRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Event not found after refreshEventGrocery."]
            )
        }
        #endif
        let event = try await apiClient.refreshEventGrocery(eventID: eventID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func mergeEventGroceryIntoWeek(eventID: String, weekID: String) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            guard let event = repo.mergeEventGroceryIntoWeek(eventID: eventID, weekID: weekID) else {
                throw NSError(
                    domain: "SimmerSmith.EventRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found after mergeEventGroceryIntoWeek."]
                )
            }
            mirrorEventsFromRepository()
            return event
        }
        #endif
        let event = try await apiClient.mergeEventGroceryIntoWeek(eventID: eventID, weekID: weekID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func unmergeEventGroceryFromWeek(eventID: String, weekID: String) async throws -> Event {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            guard let event = repo.unmergeEventGroceryFromWeek(eventID: eventID, weekID: weekID) else {
                throw NSError(
                    domain: "SimmerSmith.EventRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found after unmergeEventGroceryFromWeek."]
                )
            }
            mirrorEventsFromRepository()
            return event
        }
        #endif
        let event = try await apiClient.unmergeEventGroceryFromWeek(eventID: eventID, weekID: weekID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    // MARK: - Helpers

    func syncSummary(from event: Event) {
        let summary = EventSummary(
            eventId: event.eventId,
            name: event.name,
            eventDate: event.eventDate,
            occasion: event.occasion,
            attendeeCount: event.attendeeCount,
            status: event.status,
            linkedWeekId: event.linkedWeekId,
            mealCount: event.meals.count,
            createdAt: event.createdAt,
            updatedAt: event.updatedAt
        )
        if let index = eventSummaries.firstIndex(where: { $0.eventId == event.eventId }) {
            eventSummaries[index] = summary
        } else {
            eventSummaries.append(summary)
        }
        eventSummaries.sort { left, right in
            switch (left.eventDate, right.eventDate) {
            case let (l?, r?): return l < r
            case (nil, nil): return left.updatedAt > right.updatedAt
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }
    }
}
