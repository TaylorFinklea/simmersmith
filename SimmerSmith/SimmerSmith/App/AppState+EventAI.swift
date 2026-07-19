import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import AIProviderKit
#endif

// SP-C AI-3: AI-backed event-menu and event-meal-recipe generation.
// Isolated from AppState+Events.swift to avoid the `EventMenuResponse` / `EventAttendee`
// type-name collision: both SimmerSmithKit and AIProviderKit export those names with
// different shapes. By importing AIProviderKit only here, the unqualified names in the
// return types (EventMenuResponse, RecipeDraft) resolve to SimmerSmithKit, while the
// prompt-construction code uses `AIProviderKit.EventAttendee` etc. explicitly.

extension AppState {

    /// SP-C AI-3: generate an event menu via AIService (BYO-key LLM).
    /// Builds the event context → prompts the model → parses → adds each dish via
    /// `EventRepository.addEventMeal` → calls `refreshEventGrocery`. Un-gated:
    /// the `isCloudKitOnly` guard is removed; the method requires an AI key and surfaces
    /// `AIServiceError.noKeyConfigured` (the AI-1 pattern) when none is set.
    @discardableResult
    func generateEventMenu(
        eventID: String,
        prompt: String = "",
        roles: [String] = []
    ) async throws -> EventMenuResponse {
        #if canImport(CloudKit)
        if let aiSvc = aiService, let eventRepo = eventRepository {
            // 1. Fetch the event (may already be in eventDetails).
            let event: Event
            if let cached = eventRepo.event(forId: eventID) {
                event = cached
            } else {
                event = try await fetchEvent(eventID: eventID)
            }

            // 2. Build the menu prompt context from the live event.
            let dateISO: String
            if let d = event.eventDate {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = "yyyy-MM-dd"
                dateISO = f.string(from: d)
            } else {
                dateISO = ""
            }
            let menuContext = AIProviderKit.EventMenuContext(
                name: event.name,
                occasion: event.occasion,
                dateISO: dateISO,
                attendeeCount: event.attendeeCount,
                notes: event.notes
            )
            // Map domain EventAttendee → AIProviderKit.EventAttendee for the prompt.
            let promptAttendees: [AIProviderKit.EventAttendee] = event.attendees.map { attendee in
                AIProviderKit.EventAttendee(
                    guestId: attendee.guestId,
                    name: attendee.guest.name,
                    plusOnes: attendee.plusOnes,
                    relationshipLabel: attendee.guest.relationshipLabel,
                    ageGroup: attendee.guest.ageGroup,
                    allergies: attendee.guest.allergies,
                    dietaryNotes: attendee.guest.dietaryNotes
                )
            }
            let preassigned: [AIProviderKit.PreassignedMeal] = event.meals.map { meal in
                // Resolve assignee name from the guest list.
                let assigneeName: String
                if let assignedID = meal.assignedGuestId,
                   let match = event.attendees.first(where: { $0.guestId == assignedID }) {
                    assigneeName = match.guest.name
                } else {
                    assigneeName = ""
                }
                return AIProviderKit.PreassignedMeal(
                    role: meal.role,
                    recipeName: meal.recipeName,
                    aiGenerated: meal.aiGenerated,
                    assignedGuestName: assigneeName
                )
            }
            let unitSystem = UnitSystem.normalized(
                (profileRepository?.settings["unit_system"]) ?? (profile?.settings["unit_system"])
            )
            let resolvedRoles = roles.isEmpty ? EventMenuPrompt.defaultRoles : roles
            let menuPrompt = EventMenuPrompt.buildPrompt(
                event: menuContext,
                attendees: promptAttendees,
                roles: resolvedRoles,
                preassignedMeals: preassigned,
                userPrompt: prompt,
                unitSystem: unitSystem
            )

            // 3. Call the AI (structured JSON).
            let request = AIRequest(
                feature: .weekGen,
                prompt: menuPrompt,
                wantsStructuredJSON: true
            )
            let aiResponse = try await aiSvc.generate(request)

            // 4. Parse + resolve coverage (names → guest ids).
            let nameToID = EventMenuPrompt.nameToGuestId(promptAttendees)
            let menuResult = try EventMenuParser.parseAndResolve(
                aiResponse.text,
                nameToGuestId: nameToID,
                attendeeCount: event.attendeeCount
            )

            // 5. Replace prior AI dishes, then apply each fresh dish via addEventMeal.
            //    Server authority (`events.py replace_event_meals(preserve_manual=True)`):
            //    DELETE the event's existing ai_generated meals first (keeping manual /
            //    guest-assigned ones), then add each new dish stamped ai_generated:true with its
            //    resolved constraint_coverage AND its parsed ingredients — so a 2nd generate
            //    REPLACES (not accretes) the AI dishes and the dish ingredients feed the grocery.
            try eventRepo.deleteAIGeneratedEventMeals(eventID: eventID)
            var latestEvent: Event = event
            for dish in menuResult.dishes {
                let servings = dish.servings ?? Double(max(event.attendeeCount, 1))
                let ingredients: [EventRepository.EventMealIngredientInput] = dish.ingredients.map { ing in
                    EventRepository.EventMealIngredientInput(
                        ingredientName: ing.ingredientName,
                        quantity: ing.quantity,
                        unit: ing.unit,
                        prep: ing.prep,
                        category: ing.category,
                        notes: ing.notes
                    )
                }
                if let updated = try eventRepo.addEventMeal(
                    eventID: eventID,
                    role: dish.role,
                    recipeName: dish.recipeName,
                    recipeID: nil,
                    servings: servings,
                    notes: dish.notes,
                    assignedGuestID: nil,
                    aiGenerated: true,
                    constraintCoverage: dish.constraintCoverage,
                    ingredients: ingredients
                ) {
                    latestEvent = updated
                }
            }

            // 6. Regenerate the event grocery.
            try eventRepo.refreshEventGrocery(eventID: eventID)
            if let refreshed = eventRepo.event(forId: eventID) {
                latestEvent = refreshed
            }
            mirrorEventsFromRepository()
            eventDetails[latestEvent.eventId] = latestEvent
            syncSummary(from: latestEvent)
            return EventMenuResponse(event: latestEvent, coverageSummary: menuResult.coverageSummary)
        }
        #endif
        // Pre-CloudKit-session or no AI service: surface a clear error (no Fly fallback for
        // LLM features; the caller must configure a key via Settings → AI).
        throw NSError(
            domain: "SimmerSmith.EventRepository",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: "AI menu generation requires an AI key — open Settings → AI to add yours."]
        )
    }

    /// SP-C AI-3: generate a detailed recipe for one event meal via AIService (BYO-key LLM).
    /// Ports `event_ai._build_per_dish_prompt`: builds the event guest-constraint block →
    /// prompts the model with `RecipeAIPrompt.eventMealRecipePrompt` → parses with
    /// `RecipeAIParser.parseRecipe` → returns a `RecipeDraft`. The save path (through
    /// `RecipeRepository.save`) and the event-meal link (via `recipeId`) are the caller's
    /// responsibility (EventMealEditorSheet does this via its `onSave` callback). Un-gated.
    @discardableResult
    func generateEventMealRecipe(
        eventID: String,
        mealID: String,
        prompt: String = "",
        servings: Int = 0
    ) async throws -> RecipeDraft {
        #if canImport(CloudKit)
        if let aiSvc = aiService, let eventRepo = eventRepository {
            // 1. Resolve the event + the specific meal.
            let event: Event
            if let cached = eventRepo.event(forId: eventID) {
                event = cached
            } else {
                event = try await fetchEvent(eventID: eventID)
            }
            let meal = event.meals.first(where: { $0.mealId == mealID })

            // 2. Build the attendee constraint block (mirrors _describe_guests).
            let promptAttendees: [AIProviderKit.EventAttendee] = event.attendees.map { attendee in
                AIProviderKit.EventAttendee(
                    guestId: attendee.guestId,
                    name: attendee.guest.name,
                    plusOnes: attendee.plusOnes,
                    relationshipLabel: attendee.guest.relationshipLabel,
                    ageGroup: attendee.guest.ageGroup,
                    allergies: attendee.guest.allergies,
                    dietaryNotes: attendee.guest.dietaryNotes
                )
            }
            let constraintsBlock = EventMenuPrompt.describeGuests(promptAttendees)

            // 3. Resolve the dish name and final servings.
            let dishName = meal?.recipeName ?? "Untitled Dish"
            let effectiveServings = servings > 0 ? servings : max(event.attendeeCount, 1)

            // 4. Build + fire the prompt.
            let unitSystem = UnitSystem.normalized(
                (profileRepository?.settings["unit_system"]) ?? (profile?.settings["unit_system"])
            )
            let mealPrompt = RecipeAIPrompt.eventMealRecipePrompt(
                dishName: dishName,
                servings: effectiveServings,
                eventName: event.name,
                occasion: event.occasion,
                constraintsBlock: constraintsBlock,
                userPrompt: prompt,
                unit: unitSystem
            )
            let request = AIRequest(
                feature: .companionDraft,
                prompt: mealPrompt,
                wantsStructuredJSON: true
            )
            let aiResponse = try await aiSvc.generate(request)

            // 5. Parse into a RecipeDraft (reuses AI-2's parseRecipe shape).
            let wire = try RecipeAIParser.parseRecipe(aiResponse.text)
            return eventMealRecipeDraft(wire: wire, eventName: event.name)
        }
        #endif
        // No AI service available (pre-session or no key): surface a clear error.
        throw NSError(
            domain: "SimmerSmith.EventRepository",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: "AI recipe generation requires an AI key — open Settings → AI to add yours."]
        )
    }

    /// Map a `RecipeAIRecipe` wire value onto a `RecipeDraft` for an event-meal recipe.
    private func eventMealRecipeDraft(wire: RecipeAIRecipe, eventName: String) -> RecipeDraft {
        let ingredients: [RecipeIngredient] = wire.ingredients.map { ai in
            RecipeIngredient(
                ingredientName: ai.ingredientName,
                resolutionStatus: "unresolved",
                quantity: ai.quantity,
                unit: ai.unit,
                prep: ai.prep,
                category: ai.category,
                notes: ai.notes
            )
        }
        let steps: [RecipeStep] = wire.steps.enumerated().map { index, ai in
            RecipeStep(sortOrder: index + 1, instruction: ai.instruction)
        }
        let summary = steps
            .map { "\($0.sortOrder). \($0.instruction)" }
            .joined(separator: "\n")
        return RecipeDraft(
            name: wire.name,
            mealType: wire.mealType,
            cuisine: wire.cuisine,
            servings: wire.servings,
            prepMinutes: wire.prepMinutes,
            cookMinutes: wire.cookMinutes,
            tags: wire.tags,
            instructionsSummary: summary,
            source: "ai_event_meal",
            sourceLabel: eventName,
            sourceUrl: "",
            notes: wire.notes,
            ingredients: ingredients,
            steps: steps
        )
    }
}
