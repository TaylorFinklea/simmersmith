import Foundation
import SimmerSmithKit

extension AppState {
    // MARK: - Guests

    func refreshGuests() async {
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
            guests.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return updated
    }

    func deleteGuest(_ guest: Guest) async throws {
        try await apiClient.deleteGuest(guestID: guest.guestId)
        guests.removeAll { $0.guestId == guest.guestId }
    }

    // MARK: - Events

    func refreshEvents() async {
        guard hasSavedConnection else { return }
        do {
            eventSummaries = try await apiClient.fetchEvents()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func fetchEvent(eventID: String) async throws -> Event {
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
        attendees: [(guestID: String, plusOnes: Int)] = []
    ) async throws -> Event {
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
        attendees: [(guestID: String, plusOnes: Int)]
    ) async throws -> Event {
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
        let event = try await apiClient.deleteEventMeal(eventID: eventID, mealID: mealID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func generateEventMenu(
        eventID: String,
        prompt: String = "",
        roles: [String] = []
    ) async throws -> EventMenuResponse {
        let response = try await apiClient.generateEventMenu(
            eventID: eventID,
            prompt: prompt,
            roles: roles
        )
        eventDetails[response.event.eventId] = response.event
        syncSummary(from: response.event)
        return response
    }

    @discardableResult
    func refreshEventGrocery(eventID: String) async throws -> Event {
        let event = try await apiClient.refreshEventGrocery(eventID: eventID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func mergeEventGroceryIntoWeek(eventID: String, weekID: String) async throws -> Event {
        let event = try await apiClient.mergeEventGroceryIntoWeek(eventID: eventID, weekID: weekID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    @discardableResult
    func unmergeEventGroceryFromWeek(eventID: String, weekID: String) async throws -> Event {
        let event = try await apiClient.unmergeEventGroceryFromWeek(eventID: eventID, weekID: weekID)
        eventDetails[event.eventId] = event
        syncSummary(from: event)
        return event
    }

    // MARK: - Helpers

    private func syncSummary(from event: Event) {
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
