import Foundation
import Observation
import SimmerSmithKit

/// Global coordinator for the SimmerSmith AI assistant overlay.
///
/// Holds the current page context (replaced by views on `.onAppear`), the
/// thread used by the overlay, and the in-flight streaming state. Views
/// never create threads directly — they just update context and let the
/// coordinator reuse/start a thread as needed.
@MainActor
@Observable
final class AIAssistantCoordinator {
    // Sheet state
    var isSheetPresented: Bool = false
    var hideFloatingButton: Bool = false

    // Context
    var currentContext: AIPageContext? = nil

    // Thread
    var currentThreadID: String? = nil

    // Chat state
    var isSending: Bool = false
    var errorMessage: String = ""

    // Input
    var composerText: String = ""

    private let appState: AppState
    // Retained so we can cancel the in-flight stream when the user dismisses
    // the sheet mid-turn. Cancellation propagates through the URLSession
    // bytes(...) iteration → stream continuation finishes → server sees
    // request.is_disconnected() and aborts the OpenAI tool loop.
    private var sendTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Context

    func updateContext(_ context: AIPageContext) {
        currentContext = context
    }

    // MARK: - Presentation

    func toggle() {
        isSheetPresented.toggle()
    }

    func present() {
        isSheetPresented = true
    }

    func dismiss() {
        isSheetPresented = false
    }

    /// Cancel any in-flight streaming turn. Called by the sheet view on
    /// disappear so closing the sheet doesn't leave the server burning
    /// tokens on a reply the user won't see.
    func cancelInFlightTurn() {
        sendTask?.cancel()
        sendTask = nil
    }

    // MARK: - Messages

    var currentMessages: [AssistantMessage] {
        guard let id = currentThreadID else { return [] }
        return appState.assistantThreadDetails[id]?.messages ?? []
    }

    func startNewConversation() {
        currentThreadID = nil
        errorMessage = ""
    }

    /// Ensures we have a thread to send on. Uses a chat-kind thread — the
    /// backend now switches to the tool loop based on the per-message
    /// page_context, so we don't need a planning-kind thread.
    @discardableResult
    private func ensureThread() async throws -> String {
        if let id = currentThreadID,
           appState.assistantThreads.contains(where: { $0.threadId == id }) {
            return id
        }
        let title = currentContext?.pageLabel.isEmpty == false
            ? "Chat — \(currentContext?.pageLabel ?? "")"
            : "AI Assistant"
        let summary = try await appState.createAssistantThread(title: title)
        currentThreadID = summary.threadId
        return summary.threadId
    }

    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        composerText = ""
        errorMessage = ""
        isSending = true
        // Retain the task so cancelInFlightTurn() can cancel it. Use
        // `await task.value` to preserve the async-sendMessage contract.
        let task = Task { [weak self] () -> Void in
            await self?._performSend(trimmed)
        }
        sendTask = task
        await task.value
        sendTask = nil
        isSending = false
    }

    private func _performSend(_ text: String) async {
        do {
            let threadID = try await ensureThread()
            if appState.assistantThreadDetails[threadID] == nil {
                try? await appState.fetchAssistantThread(threadID: threadID)
            }
            // `intent` stays "general" — page_context.weekId is what tells the
            // backend to use the planning tool loop. Sending "planning" tripped
            // an older backend's strict Literal validator → 422 → iOS saw
            // "invalid response" instead of the real detail.
            try await appState.sendAssistantMessage(
                threadID: threadID,
                text: text,
                intent: "general",
                pageContext: currentContext
            )
            if let threadError = appState.assistantErrorByThreadID[threadID], !threadError.isEmpty {
                errorMessage = threadError
            }
        } catch is CancellationError {
            // Expected path when the user dismisses the sheet mid-stream.
            // Leave errorMessage empty so nothing surfaces in the UI.
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
