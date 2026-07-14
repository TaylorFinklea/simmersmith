import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import AIProviderKit
#endif

extension AppState {

    // MARK: - Thread list

    /// SP-C AI-5: refreshes `assistantThreads` from the private-plane `AssistantRepository`.
    /// No-op when the repository isn't live yet (pre-boot / iCloud unavailable).
    func refreshAssistantThreads() async {
        #if canImport(CloudKit)
        guard let repo = assistantRepository else { return }
        assistantThreads = repo.listThreads()
        #endif
    }

    // MARK: - Thread CRUD

    /// SP-C AI-5: loads a single thread from the private plane and caches it in
    /// `assistantThreadDetails`. Falls back to a nil-result (thread not found) rather
    /// than throwing so callers can degrade gracefully.
    @discardableResult
    func fetchAssistantThread(threadID: String) async throws -> AssistantThread {
        #if canImport(CloudKit)
        guard let repo = assistantRepository else {
            throw AssistantRepositoryError.storeUnavailable
        }
        guard let thread = repo.thread(id: threadID) else {
            throw AssistantRepositoryError.threadNotFound(threadID)
        }
        assistantThreadDetails[threadID] = thread
        upsertAssistantThreadSummary(
            AssistantThreadSummary(
                threadId: thread.threadId,
                title: thread.title,
                preview: thread.preview,
                threadKind: thread.threadKind,
                linkedWeekId: thread.linkedWeekId,
                createdAt: thread.createdAt,
                updatedAt: thread.updatedAt
            )
        )
        return thread
        #else
        throw AssistantRepositoryError.storeUnavailable
        #endif
    }

    func createAssistantThread(
        title: String = "",
        threadKind: String = "chat",
        linkedWeekID: String? = nil
    ) async throws -> AssistantThreadSummary {
        #if canImport(CloudKit)
        guard let repo = assistantRepository else {
            throw AssistantRepositoryError.storeUnavailable
        }
        let thread = try repo.createThread(
            title: title,
            threadKind: threadKind,
            linkedWeekID: linkedWeekID
        )
        upsertAssistantThreadSummary(thread)
        return thread
        #else
        throw AssistantRepositoryError.storeUnavailable
        #endif
    }

    func deleteAssistantThread(threadID: String) async throws {
        #if canImport(CloudKit)
        guard let repo = assistantRepository else {
            throw AssistantRepositoryError.storeUnavailable
        }
        try repo.deleteThread(id: threadID)
        assistantThreads.removeAll { $0.threadId == threadID }
        assistantThreadDetails.removeValue(forKey: threadID)
        assistantErrorByThreadID.removeValue(forKey: threadID)
        #else
        throw AssistantRepositoryError.storeUnavailable
        #endif
    }

    // MARK: - Launch context

    /// Bead simmersmith-7pr: creates a fresh thread and opens the REAL
    /// assistant sheet via the coordinator (not the Smith tab's dead
    /// ComingSoon route). `attachedRecipeID` / `attachedRecipeDraft` /
    /// `intent` are accepted for call-site compatibility but only the
    /// composer prefill (`initialText`) reaches the coordinator today —
    /// the send path never forwarded an attached draft even before this
    /// change, so this is not a regression.
    func beginAssistantLaunch(
        initialText: String = "",
        title: String = "",
        attachedRecipeID: String? = nil,
        attachedRecipeDraft: RecipeDraft? = nil,
        intent: String = "general",
        threadKind: String = "chat",
        linkedWeekID: String? = nil
    ) async throws {
        let thread = try await createAssistantThread(
            title: title,
            threadKind: threadKind,
            linkedWeekID: linkedWeekID
        )
        assistantCoordinator.startNewConversation()
        assistantCoordinator.currentThreadID = thread.threadId
        assistantCoordinator.composerText = initialText
        _ = try? await fetchAssistantThread(threadID: thread.threadId)
        assistantCoordinator.present()
    }

    // MARK: - Send message (on-device engine)

    /// SP-C AI-5: sends a user message and runs the on-device `AssistantEngine` tool-calling
    /// loop. Flow:
    ///   1. Persist the user message via `AssistantRepository.appendMessage`.
    ///   2. Emit a `user_message.created` event so the UI renders it immediately.
    ///   3. Build the conversation history from the thread's stored messages.
    ///   4. Run `AssistantEngine.run(...)` with the BYO provider + `ToolRegistry` runner.
    ///   5. Forward each `AssistantStreamEvent` into the EXISTING `applyAssistantStreamEvent`
    ///      (unchanged UI handler) as an `AssistantStreamEnvelope`.
    ///   6. On completion, persist the final assistant message via the repository.
    ///   7. On cancellation (sheet dismiss), mark the in-flight row cancelled locally.
    func sendAssistantMessage(
        threadID: String,
        text: String,
        attachedRecipeID: String? = nil,
        attachedRecipeDraft: RecipeDraft? = nil,
        intent: String = "general",
        pageContext: AIPageContext? = nil
    ) async throws {
        #if canImport(CloudKit)
        guard let repo = assistantRepository, let aiSvc = aiService else {
            // Pre-session: fall back to a clean error (no Fly call).
            throw AssistantRepositoryError.storeUnavailable
        }

        assistantSendingThreadIDs.insert(threadID)
        assistantErrorByThreadID[threadID] = nil
        defer { assistantSendingThreadIDs.remove(threadID) }

        // 1. Persist the user message.
        let userMsgID = UUID().uuidString
        let userCreatedAt = Date()
        let _ = try repo.appendMessage(
            threadID: threadID,
            role: "user",
            content: text,
            status: "completed",
            attachedRecipeID: attachedRecipeID,
            messageID: userMsgID,
            createdAt: userCreatedAt
        )

        // 2. Emit user_message.created so the UI renders it immediately (before engine starts).
        let userMsgEvent = makeUserMessageCreatedEvent(
            messageID: userMsgID,
            threadID: threadID,
            content: text,
            attachedRecipeID: attachedRecipeID,
            createdAt: userCreatedAt
        )
        try applyAssistantStreamEvent(threadID: threadID, event: userMsgEvent)

        // 3. Build the conversation history. `PrivatePlaneStore.messages(forThreadID:)`
        //    sorts createdAt FORWARD, so these arrive oldest-first (chronological) and
        //    already include the just-added user message as the last entry. The engine
        //    appends `userText` itself, so we drop that last entry below (priorHistory).
        let history: [AIChatMessage]
        if let detail = repo.thread(id: threadID) {
            history = detail.messages
                .filter { $0.status == "completed" && ($0.role == "user" || $0.role == "assistant") }
                .map { AIChatMessage.text($0.role == "user" ? .user : .assistant, $0.contentMarkdown) }
        } else {
            history = [AIChatMessage.text(.user, text)]
        }
        // Drop the last history entry (it's the user message we just added — the engine
        // appends it internally via `userText`). The final n-1 are the prior turns.
        let priorHistory = history.dropLast()

        // 4. Build the system prompt + ToolRegistry and run the engine.
        //
        // bead simmersmith-48y: the active week id is the page the user is LOOKING AT
        // (pageContext, set on every `.onAppear`/browse change) over the app's browsed/
        // current slots — so a turn started while browsing "next week" acts on that
        // week, not silently `currentWeek`. Thread it into BOTH the ToolRegistry (so
        // `weeks_get_current`/`grocery_get` resolve it through the repo) and the system
        // prompt's planningContext block (so the model can act on the id directly
        // without an extra `weeks_get_current` round-trip).
        let threadTitle = assistantThreadDetails[threadID]?.title ?? ""
        let activeWeekID = resolveActiveWeekID(pageContext: pageContext)
        let toolRegistry = ToolRegistry(appState: self, activeWeekID: activeWeekID)
        let gatheredContext = gatherWeekGenContext(excludeWeekId: activeWeekID)
        let activeWeekSummary = toolRegistry.resolvedActiveWeek().map(self.describeActiveWeekForAssistant) ?? ""
        let planningContext = AssistantSystemPrompt.renderPlanningContext(
            gatheredContext,
            activeWeekSummary: activeWeekSummary,
            todayISO: DayKey.local(Date())
        )
        let systemPrompt = AssistantSystemPrompt.build(
            threadTitle: threadTitle,
            planningContext: planningContext,
            unitSystem: unitSystemDraft == "metric" ? .metric : .us
        )
        let provider = try aiSvc.makeAssistantProvider()

        let engineStream = AssistantEngine.run(
            systemPrompt: systemPrompt,
            history: Array(priorHistory),
            userText: text,
            tools: toolRegistry.specs,
            threadId: threadID,
            provider: provider,
            runner: toolRegistry.runner
        )

        // Track the final assistant content + message id for persistence.
        var finalContent = ""
        var assistantMsgID = UUID().uuidString

        do {
            for try await event in engineStream {
                // C2 (review): a throw from `applyAssistantStreamEvent` (a malformed
                // single event → DecodingError) must NOT kill the conversation. Catch
                // non-cancellation errors per-event: log and CONTINUE the stream so the
                // remaining events (incl. assistant.completed) still process and the
                // final message still persists. Only a true CancellationError (sheet
                // dismissed) breaks out — handled by the outer catch.
                let envelope = AssistantStreamEnvelope(event: event.event, data: event.data)
                do {
                    try applyAssistantStreamEvent(threadID: threadID, event: envelope)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A single malformed event — log it (debug) and keep processing.
                    // We deliberately do NOT surface a raw DecodingError to the user via
                    // `assistantErrorByThreadID`: one bad event must not abort the turn.
                    assertionFailure("applyAssistantStreamEvent failed for \(event.event): \(error)")
                }

                // Capture the message id and final content from the engine's events.
                // This runs even if `applyAssistantStreamEvent` above threw, so the final
                // assistant message is still persisted from the accumulated content.
                switch event.event {
                case "assistant.message.created":
                    if let decoded = try? SimmerSmithJSONCoding.makeDecoder()
                        .decode(AssistantMessage.self, from: event.data) {
                        assistantMsgID = decoded.messageId
                    }
                case "assistant.delta":
                    // Fallback accumulator: if the completed event is itself malformed,
                    // we still have the streamed text to persist. v1 emits the whole
                    // reply in one delta, so this captures the full content.
                    if let decoded = try? SimmerSmithJSONCoding.makeDecoder()
                        .decode(AssistantDeltaEvent.self, from: event.data) {
                        finalContent += decoded.delta
                    }
                case "assistant.completed":
                    if let decoded = try? SimmerSmithJSONCoding.makeDecoder()
                        .decode(AssistantMessage.self, from: event.data) {
                        finalContent = decoded.contentMarkdown
                        assistantMsgID = decoded.messageId
                    }
                default:
                    break
                }
            }
        } catch is CancellationError {
            // Sheet dismissed — mark the row cancelled locally (same pattern as the Fly path).
            markLastStreamingAssistantAsCancelled(threadID: threadID)
            throw CancellationError()
        }

        // 5. Persist the final assistant message.
        if !finalContent.isEmpty {
            _ = try? repo.appendMessage(
                threadID: threadID,
                role: "assistant",
                content: finalContent,
                status: "completed",
                messageID: assistantMsgID,
                createdAt: Date()
            )
        }
        // Refresh the in-memory thread so the list preview updates.
        _ = try? await fetchAssistantThread(threadID: threadID)
        #else
        throw AssistantRepositoryError.storeUnavailable
        #endif
    }

    // MARK: - Planning context (bead simmersmith-48y)

    /// The week id the assistant should act on for THIS turn: the page the user is
    /// LOOKING AT (`pageContext`, set on every screen's `.onAppear`/browse change)
    /// takes priority over the app's browsed/current slots, so a turn started while
    /// browsing "next week" acts on that week, not silently `currentWeek`.
    func resolveActiveWeekID(pageContext: AIPageContext?) -> String? {
        pageContext?.weekId ?? browsedWeek?.weekId ?? currentWeek?.weekId
    }

    /// A short natural-language summary of the active week for the assistant's
    /// planning-context block — the meals it already knows about (id, dates, status,
    /// what's planned) without an extra `weeks_get_current` round-trip.
    private func describeActiveWeekForAssistant(_ week: WeekSnapshot) -> String {
        var lines = [
            "Active week — id: \(week.weekId), starts \(DayKey.server(week.weekStart)), status: \(week.status)."
        ]
        if week.meals.isEmpty {
            lines.append("No meals planned yet.")
        } else {
            lines.append(contentsOf: week.meals.map { meal in
                let name = meal.recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
                return "- \(meal.dayName) \(meal.slot): \(name.isEmpty ? "(empty)" : name)"
            })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Stream event handler (unchanged — UI reads from this)

    func applyAssistantStreamEvent(threadID: String, event: AssistantStreamEnvelope) throws {
        switch event.event {
        case "thread.updated":
            let summary = try event.decode(AssistantThreadSummary.self)
            upsertAssistantThreadSummary(summary)
            if var detail = assistantThreadDetails[threadID] {
                detail = AssistantThread(
                    threadId: detail.threadId,
                    title: summary.title,
                    preview: summary.preview,
                    threadKind: summary.threadKind,
                    linkedWeekId: summary.linkedWeekId,
                    createdAt: detail.createdAt,
                    updatedAt: summary.updatedAt,
                    messages: detail.messages
                )
                assistantThreadDetails[threadID] = detail
            }
        case "user_message.created":
            let message = try event.decode(AssistantMessage.self)
            appendAssistantMessage(message, to: threadID)
        case "assistant.message.created":
            // Seeded empty assistant row so tool_call events have an
            // anchor before any content delta arrives. Same decode shape
            // as user_message.created.
            let message = try event.decode(AssistantMessage.self)
            appendAssistantMessage(message, to: threadID)
        case "assistant.delta":
            let delta = try event.decode(AssistantDeltaEvent.self)
            applyAssistantDelta(threadID: threadID, delta: delta)
        case "assistant.recipe_draft":
            let draftEvent = try event.decode(AssistantRecipeDraftEvent.self)
            attachAssistantDraft(threadID: threadID, event: draftEvent)
        case "assistant.tool_call":
            let call = try event.decode(AssistantToolCall.self)
            appendAssistantToolCall(call, to: threadID)
        case "assistant.tool_result":
            let call = try event.decode(AssistantToolCall.self)
            appendAssistantToolCall(call, to: threadID)
        case "assistant.heartbeat":
            let beat = try event.decode(AssistantHeartbeatEvent.self)
            applyAssistantHeartbeat(threadID: threadID, beat: beat)
        case "week.updated":
            let updated = try event.decode(AssistantWeekUpdatedEvent.self)
            applyAssistantWeekUpdate(updated.week)
        case "assistant.completed":
            let message = try event.decode(AssistantMessage.self)
            replaceAssistantMessage(message, in: threadID)
        case "assistant.error":
            let errorEvent = try event.decode(AssistantErrorEvent.self)
            assistantErrorByThreadID[threadID] = errorEvent.detail
        default:
            break
        }
    }

    // MARK: - Week update routing

    /// Route a `week.updated` SSE payload to whichever week slot matches
    /// by `weekId`. The previous implementation unconditionally wrote to
    /// `currentWeek`, which corrupted "this week" whenever the assistant
    /// mutated a non-current week (e.g. planning "next week" from the
    /// week-picker browsed view) — and left the browsed week stale, so
    /// the user saw an empty day even after the AI reported success.
    private func applyAssistantWeekUpdate(_ week: WeekSnapshot) {
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        } else if browsedWeek?.weekId == week.weekId {
            browsedWeek = week
        }
        // If the AI mutated a week we're not tracking right now (e.g.
        // user navigated away while the turn was in flight), drop the
        // payload — the next fetch/refetch will pick it up server-side.
    }

    // MARK: - Cancellation / status helpers

    /// Flip the last streaming assistant row's status to "cancelled" without
    /// touching anything else. Used when the user cancels a turn — we're the
    /// ones who closed the socket, so the server's assistant.cancelled event
    /// can't reach us. Preserves any streamed content that arrived before
    /// the cancel.
    private func markLastStreamingAssistantAsCancelled(threadID: String) {
        guard var detail = assistantThreadDetails[threadID] else { return }
        guard let index = detail.messages.lastIndex(where: {
            $0.role == "assistant" && $0.status == "streaming"
        }) else { return }
        let existing = detail.messages[index]
        var messages = detail.messages
        messages[index] = AssistantMessage(
            messageId: existing.messageId,
            threadId: existing.threadId,
            role: existing.role,
            status: "cancelled",
            contentMarkdown: existing.contentMarkdown,
            recipeDraft: existing.recipeDraft,
            attachedRecipeId: existing.attachedRecipeId,
            toolCalls: existing.toolCalls,
            createdAt: existing.createdAt,
            completedAt: existing.completedAt ?? .now,
            error: existing.error
        )
        detail = AssistantThread(
            threadId: detail.threadId,
            title: detail.title,
            preview: detail.preview,
            threadKind: detail.threadKind,
            linkedWeekId: detail.linkedWeekId,
            createdAt: detail.createdAt,
            updatedAt: detail.updatedAt,
            messages: messages
        )
        assistantThreadDetails[threadID] = detail
    }

    private func appendAssistantToolCall(_ call: AssistantToolCall, to threadID: String) {
        guard let detail = assistantThreadDetails[threadID] else { return }
        // Find the last streaming assistant message; attach/replace the tool
        // call on it so the UI can render a live card. The assistant row
        // is seeded from `assistant.message.created` which the backend
        // emits before the tool loop starts — so by the time tool_call
        // events arrive there's always a row to attach to.
        guard let lastIndex = detail.messages.lastIndex(where: { $0.role == "assistant" }) else {
            return
        }
        var messages = detail.messages
        let existing = messages[lastIndex]
        var toolCalls = existing.toolCalls
        if let callIndex = toolCalls.firstIndex(where: { $0.callId == call.callId }) {
            toolCalls[callIndex] = call
        } else {
            toolCalls.append(call)
        }
        messages[lastIndex] = AssistantMessage(
            messageId: existing.messageId,
            threadId: existing.threadId,
            role: existing.role,
            status: existing.status,
            contentMarkdown: existing.contentMarkdown,
            recipeDraft: existing.recipeDraft,
            attachedRecipeId: existing.attachedRecipeId,
            toolCalls: toolCalls,
            createdAt: existing.createdAt,
            completedAt: existing.completedAt,
            error: existing.error
        )
        assistantThreadDetails[threadID] = AssistantThread(
            threadId: detail.threadId,
            title: detail.title,
            preview: detail.preview,
            threadKind: detail.threadKind,
            linkedWeekId: detail.linkedWeekId,
            createdAt: detail.createdAt,
            updatedAt: detail.updatedAt,
            messages: messages
        )
    }

    private func upsertAssistantThreadSummary(_ thread: AssistantThreadSummary) {
        if let index = assistantThreads.firstIndex(where: { $0.threadId == thread.threadId }) {
            assistantThreads[index] = thread
        } else {
            assistantThreads.append(thread)
        }
        assistantThreads.sort { $0.updatedAt > $1.updatedAt }
    }

    private func appendAssistantMessage(_ message: AssistantMessage, to threadID: String) {
        let existing = assistantThreadDetails[threadID]
        let summary = assistantThreads.first(where: { $0.threadId == threadID })
        let createdAt = existing?.createdAt ?? summary?.createdAt ?? .now
        var messages = existing?.messages ?? []
        if messages.contains(where: { $0.messageId == message.messageId }) {
            replaceAssistantMessage(message, in: threadID)
            return
        }
        messages.append(message)
        messages.sort { $0.createdAt < $1.createdAt }
        assistantThreadDetails[threadID] = AssistantThread(
            threadId: threadID,
            title: existing?.title ?? summary?.title ?? "New Assistant Chat",
            preview: existing?.preview ?? summary?.preview ?? "",
            threadKind: existing?.threadKind ?? summary?.threadKind ?? "chat",
            linkedWeekId: existing?.linkedWeekId ?? summary?.linkedWeekId,
            createdAt: createdAt,
            updatedAt: existing?.updatedAt ?? .now,
            messages: messages
        )
    }

    private func replaceAssistantMessage(_ message: AssistantMessage, in threadID: String) {
        guard var detail = assistantThreadDetails[threadID] else {
            appendAssistantMessage(message, to: threadID)
            return
        }
        if let index = detail.messages.firstIndex(where: { $0.messageId == message.messageId }) {
            var messages = detail.messages
            // Preserve any tool_calls we accumulated from SSE events if the
            // server-sent "completed" message is missing them (defensive).
            let preservedCalls = messages[index].toolCalls
            let incoming = message.toolCalls.isEmpty ? preservedCalls : message.toolCalls
            messages[index] = AssistantMessage(
                messageId: message.messageId,
                threadId: message.threadId,
                role: message.role,
                status: message.status,
                contentMarkdown: message.contentMarkdown,
                recipeDraft: message.recipeDraft,
                attachedRecipeId: message.attachedRecipeId,
                toolCalls: incoming,
                createdAt: message.createdAt,
                completedAt: message.completedAt,
                error: message.error
            )
            detail = AssistantThread(
                threadId: detail.threadId,
                title: detail.title,
                preview: detail.preview,
                threadKind: detail.threadKind,
                linkedWeekId: detail.linkedWeekId,
                createdAt: detail.createdAt,
                updatedAt: detail.updatedAt,
                messages: messages
            )
            assistantThreadDetails[threadID] = detail
        } else {
            appendAssistantMessage(message, to: threadID)
        }
    }

    private func applyAssistantDelta(threadID: String, delta: AssistantDeltaEvent) {
        if let existing = assistantThreadDetails[threadID]?.messages.first(where: { $0.messageId == delta.messageId }) {
            replaceAssistantMessage(
                AssistantMessage(
                    messageId: existing.messageId,
                    threadId: existing.threadId,
                    role: existing.role,
                    status: "streaming",
                    contentMarkdown: existing.contentMarkdown + delta.delta,
                    recipeDraft: existing.recipeDraft,
                    attachedRecipeId: existing.attachedRecipeId,
                    toolCalls: existing.toolCalls,
                    createdAt: existing.createdAt,
                    completedAt: existing.completedAt,
                    error: existing.error
                ),
                in: threadID
            )
            return
        }
        appendAssistantMessage(
            AssistantMessage(
                messageId: delta.messageId,
                threadId: threadID,
                role: "assistant",
                status: "streaming",
                contentMarkdown: delta.delta,
                recipeDraft: nil,
                attachedRecipeId: nil,
                createdAt: .now,
                completedAt: nil,
                error: ""
            ),
            to: threadID
        )
    }

    /// Apply an `assistant.heartbeat` SSE tick. In the on-device engine this is unused
    /// (no idle-timeout keep-alive is needed), but the handler is retained for parity
    /// with the Fly-backed path so no UI code needs changing.
    private func applyAssistantHeartbeat(threadID: String, beat: AssistantHeartbeatEvent) {
        _ = beat
        _ = threadID
    }

    private func attachAssistantDraft(threadID: String, event: AssistantRecipeDraftEvent) {
        guard let existing = assistantThreadDetails[threadID]?.messages.first(where: { $0.messageId == event.messageId }) else {
            return
        }
        replaceAssistantMessage(
            AssistantMessage(
                messageId: existing.messageId,
                threadId: existing.threadId,
                role: existing.role,
                status: existing.status,
                contentMarkdown: existing.contentMarkdown,
                recipeDraft: event.draft,
                attachedRecipeId: existing.attachedRecipeId,
                toolCalls: existing.toolCalls,
                createdAt: existing.createdAt,
                completedAt: existing.completedAt,
                error: existing.error
            ),
            in: threadID
        )
    }

    // MARK: - Event builders (for locally-emitted events)

    /// Build a `user_message.created` envelope for a message persisted on-device.
    /// Mirrors the snake_case JSON the Fly server emitted so `applyAssistantStreamEvent`
    /// decodes it identically.
    private func makeUserMessageCreatedEvent(
        messageID: String,
        threadID: String,
        content: String,
        attachedRecipeID: String?,
        createdAt: Date
    ) -> AssistantStreamEnvelope {
        let iso = ISO8601DateFormatter().string(from: createdAt)
        var payload: [String: Any] = [
            "message_id": messageID,
            "thread_id": threadID,
            "role": "user",
            "status": "completed",
            "content_markdown": content,
            "tool_calls": [],
            "created_at": iso,
            "error": "",
        ]
        if let rid = attachedRecipeID {
            payload["attached_recipe_id"] = rid
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return AssistantStreamEnvelope(event: "user_message.created", data: data)
    }
}

