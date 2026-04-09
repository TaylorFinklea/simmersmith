import Foundation
import SimmerSmithKit

extension AppState {
    func refreshAssistantThreads() async {
        guard hasSavedConnection else { return }
        do {
            assistantThreads = try await apiClient.fetchAssistantThreads()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func fetchAssistantThread(threadID: String) async throws -> AssistantThread {
        let thread = try await apiClient.fetchAssistantThread(threadID: threadID)
        assistantThreadDetails[threadID] = thread
        upsertAssistantThreadSummary(
            AssistantThreadSummary(
                threadId: thread.threadId,
                title: thread.title,
                preview: thread.preview,
                createdAt: thread.createdAt,
                updatedAt: thread.updatedAt
            )
        )
        return thread
    }

    func createAssistantThread(title: String = "") async throws -> AssistantThreadSummary {
        let thread = try await apiClient.createAssistantThread(title: title)
        upsertAssistantThreadSummary(thread)
        return thread
    }

    func deleteAssistantThread(threadID: String) async throws {
        try await apiClient.deleteAssistantThread(threadID: threadID)
        assistantThreads.removeAll { $0.threadId == threadID }
        assistantThreadDetails.removeValue(forKey: threadID)
        assistantErrorByThreadID.removeValue(forKey: threadID)
    }

    func beginAssistantLaunch(
        initialText: String = "",
        title: String = "",
        attachedRecipeID: String? = nil,
        attachedRecipeDraft: RecipeDraft? = nil,
        intent: String = "general"
    ) async throws {
        let thread = try await createAssistantThread(title: title)
        assistantLaunchContext = AssistantLaunchContext(
            threadID: thread.threadId,
            initialText: initialText,
            attachedRecipeID: attachedRecipeID,
            attachedRecipeDraft: attachedRecipeDraft,
            intent: intent
        )
        selectedTab = .assistant
        _ = try? await fetchAssistantThread(threadID: thread.threadId)
    }

    func consumeAssistantLaunchContext() -> AssistantLaunchContext? {
        defer { assistantLaunchContext = nil }
        return assistantLaunchContext
    }

    func sendAssistantMessage(
        threadID: String,
        text: String,
        attachedRecipeID: String? = nil,
        attachedRecipeDraft: RecipeDraft? = nil,
        intent: String = "general"
    ) async throws {
        assistantSendingThreadIDs.insert(threadID)
        assistantErrorByThreadID[threadID] = nil
        defer { assistantSendingThreadIDs.remove(threadID) }

        let initialMessageCount = assistantThreadDetails[threadID]?.messages.count ?? 0
        let stream = try await apiClient.streamAssistantResponse(
            threadID: threadID,
            text: text,
            attachedRecipeID: attachedRecipeID,
            attachedRecipeDraft: attachedRecipeDraft,
            intent: intent
        )
        var streamFailure: Error?
        do {
            for try await event in stream {
                try applyAssistantStreamEvent(threadID: threadID, event: event)
            }
        } catch {
            streamFailure = error
        }
        let refreshedThread = try? await fetchAssistantThread(threadID: threadID)
        if let streamFailure {
            let refreshedCount = refreshedThread?.messages.count ?? 0
            if refreshedCount > initialMessageCount {
                assistantErrorByThreadID[threadID] = "Response may be incomplete. Pull to refresh."
                return
            }
            throw streamFailure
        }
    }

    private func applyAssistantStreamEvent(threadID: String, event: AssistantStreamEnvelope) throws {
        switch event.event {
        case "thread.updated":
            let summary = try event.decode(AssistantThreadSummary.self)
            upsertAssistantThreadSummary(summary)
            if var detail = assistantThreadDetails[threadID] {
                detail = AssistantThread(
                    threadId: detail.threadId,
                    title: summary.title,
                    preview: summary.preview,
                    createdAt: detail.createdAt,
                    updatedAt: summary.updatedAt,
                    messages: detail.messages
                )
                assistantThreadDetails[threadID] = detail
            }
        case "user_message.created":
            let message = try event.decode(AssistantMessage.self)
            appendAssistantMessage(message, to: threadID)
        case "assistant.delta":
            let delta = try event.decode(AssistantDeltaEvent.self)
            applyAssistantDelta(threadID: threadID, delta: delta)
        case "assistant.recipe_draft":
            let draftEvent = try event.decode(AssistantRecipeDraftEvent.self)
            attachAssistantDraft(threadID: threadID, event: draftEvent)
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
        let createdAt = existing?.createdAt ?? assistantThreads.first(where: { $0.threadId == threadID })?.createdAt ?? .now
        var messages = existing?.messages ?? []
        if messages.contains(where: { $0.messageId == message.messageId }) {
            replaceAssistantMessage(message, in: threadID)
            return
        }
        messages.append(message)
        messages.sort { $0.createdAt < $1.createdAt }
        assistantThreadDetails[threadID] = AssistantThread(
            threadId: threadID,
            title: existing?.title ?? assistantThreads.first(where: { $0.threadId == threadID })?.title ?? "New Assistant Chat",
            preview: existing?.preview ?? assistantThreads.first(where: { $0.threadId == threadID })?.preview ?? "",
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
            messages[index] = message
            detail = AssistantThread(
                threadId: detail.threadId,
                title: detail.title,
                preview: detail.preview,
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
                createdAt: existing.createdAt,
                completedAt: existing.completedAt,
                error: existing.error
            ),
            in: threadID
        )
    }
}
