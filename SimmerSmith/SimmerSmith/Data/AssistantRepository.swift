#if canImport(CloudKit)
import Foundation
import Observation
import SimmerSmithKit

// SP-C AI-5 (T3) — AssistantRepository: assistant conversation storage over the per-user
// PRIVATE plane (NSPersistentCloudKitContainer). Mirrors ProfileRepository's shape:
// `init(session:)`, reaches the private plane through `session.privateStore`
// (`PrivatePlaneStore`), guards a nil store (pre-boot / iCloud unavailable) by degrading
// to empty rather than throwing.
//
// This is the device-side replacement for the Fly assistant-thread endpoints
// (`fetchAssistantThreads` / `fetchAssistantThread` / `createAssistantThread` /
// `deleteAssistantThread`). The AppState+Assistant rewire (T5) calls these instead of the
// `apiClient.*` paths.
//
// Projection (PrivateAssistant* ⇄ the iOS domain types):
//   PrivateAssistantThread (recordKey/title/createdAt/updatedAt/linkedWeekID/archived +
//     a .cascade `messages` relationship) ⇄ AssistantThreadSummary / AssistantThread.
//   PrivateAssistantMessage (recordKey/role/content/createdAt/status/attachedRecipeID) ⇄
//     AssistantMessage.
//
// Two fields the iOS domain types carry but the private-plane model does NOT store, so the
// projection DERIVES them (faithful to how the Fly payload computed them):
//   - `preview`    — the trimmed text of the thread's most recent message.
//   - `threadKind` — always "chat" (the only kind the on-device assistant creates; the
//     server's planning/linked-week kinds aren't re-modeled in the private plane).
// And two the model can't hold, so they project as empty/nil on read:
//   - `toolCalls`  — transient SSE state attached live by `applyAssistantStreamEvent`; the
//     persisted assistant row keeps the final summary text, not the tool transcript.
//   - `recipeDraft` / `error` — empty (a saved message is a terminal record).

@MainActor
@Observable
final class AssistantRepository {

    // MARK: - Plumbing

    private let session: HouseholdSession

    // MARK: - Init

    init(session: HouseholdSession) {
        self.session = session
    }

    // MARK: - Threads

    /// All assistant threads as summaries, newest `updatedAt` first (matches the Fly list
    /// order + `AppState.upsertAssistantThreadSummary`'s sort). Archived threads are hidden,
    /// mirroring the server's default thread list.
    func listThreads() -> [AssistantThreadSummary] {
        guard let store = session.privateStore else { return [] }
        do {
            let threads = try store.allAssistantThreads()
                .filter { !$0.archived }
            return threads
                .map { summary(from: $0, lastMessage: latestMessage(for: $0, store: store)) }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            print("[AssistantRepository] listThreads failed: \(error)")
            return []
        }
    }

    /// Create a new thread and return its summary. `threadKind` is accepted for call-site
    /// parity with the Fly client but only "chat" is persisted (see the projection note).
    @discardableResult
    func createThread(
        title: String = "",
        threadKind: String = "chat",
        linkedWeekID: String? = nil
    ) throws -> AssistantThreadSummary {
        guard let store = session.privateStore else {
            throw AssistantRepositoryError.storeUnavailable
        }
        let now = Date()
        let threadID = UUID().uuidString
        let row = try store.upsertAssistantThread(
            threadID: threadID,
            title: title,
            createdAt: now,
            updatedAt: now,
            linkedWeekID: linkedWeekID,
            archived: false
        )
        try store.save()
        return summary(from: row, lastMessage: nil)
    }

    /// Delete a thread (its messages cascade via the model's `.cascade` rule).
    func deleteThread(id threadID: String) throws {
        guard let store = session.privateStore else {
            throw AssistantRepositoryError.storeUnavailable
        }
        guard let row = try store.assistantThread(threadID: threadID) else { return }
        store.context.delete(row)
        try store.save()
    }

    /// Fetch a thread with its messages in transcript order, or nil when it doesn't exist.
    func thread(id threadID: String) -> AssistantThread? {
        guard let store = session.privateStore else { return nil }
        do {
            guard let row = try store.assistantThread(threadID: threadID) else { return nil }
            let messageRows = try store.messages(forThreadID: threadID)
            let messages = messageRows.map { message(from: $0, threadID: threadID) }
            let preview = messageRows.last.map { Self.preview(from: $0.content) } ?? ""
            return AssistantThread(
                threadId: row.recordKey,
                title: row.title,
                preview: preview,
                threadKind: "chat",
                linkedWeekId: row.linkedWeekID,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt,
                messages: messages
            )
        } catch {
            print("[AssistantRepository] thread(\(threadID)) failed: \(error)")
            return nil
        }
    }

    // MARK: - Messages

    /// Append (upsert) a message to a thread and bump the thread's `updatedAt`. Returns the
    /// projected `AssistantMessage`. `toolCalls` is accepted for call-site parity (the
    /// streamed transcript) but NOT persisted — the private-plane model stores only the
    /// terminal role/content/status/attachedRecipeID; the tool cards are transient SSE.
    @discardableResult
    func appendMessage(
        threadID: String,
        role: String,
        content: String,
        status: String = "completed",
        attachedRecipeID: String? = nil,
        toolCalls: [AssistantToolCall] = [],
        messageID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> AssistantMessage {
        guard let store = session.privateStore else {
            throw AssistantRepositoryError.storeUnavailable
        }
        guard let thread = try store.assistantThread(threadID: threadID) else {
            throw AssistantRepositoryError.threadNotFound(threadID)
        }
        let row = try store.upsertAssistantMessage(
            messageID: messageID,
            thread: thread,
            role: role,
            content: content,
            createdAt: createdAt,
            status: status,
            attachedRecipeID: attachedRecipeID
        )
        // Bump the parent thread's recency so list ordering reflects the new message.
        thread.updatedAt = max(thread.updatedAt, createdAt)
        try store.save()
        return message(from: row, threadID: threadID, toolCalls: toolCalls)
    }

    // MARK: - Projection: PrivateAssistant* → iOS domain types

    /// Build a summary from a thread row. `lastMessage` (the most recent message, if any)
    /// supplies the derived `preview`.
    private func summary(
        from row: PrivateAssistantThread,
        lastMessage: PrivateAssistantMessage?
    ) -> AssistantThreadSummary {
        AssistantThreadSummary(
            threadId: row.recordKey,
            title: row.title,
            preview: lastMessage.map { Self.preview(from: $0.content) } ?? "",
            threadKind: "chat",
            linkedWeekId: row.linkedWeekID,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    /// Project a stored message row into the iOS `AssistantMessage`. `recipeDraft` / `error`
    /// are empty (a persisted row is terminal); `contentMarkdown` is the stored content;
    /// `completedAt` mirrors `createdAt` for completed rows (the model stores one timestamp).
    private func message(
        from row: PrivateAssistantMessage,
        threadID: String,
        toolCalls: [AssistantToolCall] = []
    ) -> AssistantMessage {
        AssistantMessage(
            messageId: row.recordKey,
            threadId: threadID,
            role: row.role,
            status: row.status,
            contentMarkdown: row.content,
            recipeDraft: nil,
            attachedRecipeId: row.attachedRecipeID,
            toolCalls: toolCalls,
            createdAt: row.createdAt,
            completedAt: row.status == "completed" ? row.createdAt : nil,
            error: ""
        )
    }

    /// The most recent message for a thread (for the summary preview), or nil.
    private func latestMessage(
        for thread: PrivateAssistantThread,
        store: PrivatePlaneStore
    ) -> PrivateAssistantMessage? {
        (try? store.messages(forThreadID: thread.recordKey))?.last
    }

    /// Trim a message body to a one-line preview (collapse newlines, clamp length) —
    /// mirrors the Fly thread `preview` field.
    private static func preview(from content: String) -> String {
        let collapsed = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 120 { return collapsed }
        return String(collapsed.prefix(120)) + "…"
    }
}

// MARK: - Errors

enum AssistantRepositoryError: Error, LocalizedError {
    case storeUnavailable
    case threadNotFound(String)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "The assistant store needs iCloud — try again after sync finishes."
        case .threadNotFound(let id):
            return "Assistant thread \(id) was not found."
        }
    }
}
#endif
