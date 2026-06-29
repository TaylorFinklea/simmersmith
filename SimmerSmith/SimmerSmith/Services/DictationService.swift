import AVFoundation
import Foundation
import Observation
import Speech

/// SP-C voice week-planning — free-form on-device dictation for "talk out your week".
/// Distinct from VoiceCommandService (which matches Cooking-Mode keywords): this ACCUMULATES
/// the full spoken transcript across SFSpeechRecognizer's ~1-minute buffer limit, exposing a
/// live `transcript` for the UI and returning the final text on `stop()`. Audio never leaves
/// the phone (on-device recognition when available). Modeled on VoiceCommandService's proven
/// audio-session / tap / 50s-restart plumbing (incl. the Build-66 format guards).
///
/// v1 uses SFSpeechRecognizer (works on every iOS 26 device). The iOS 26 SpeechTranscriber
/// engine is a future enhancement gated behind VoicePlanningAvailability.transcribeEngine.
@MainActor
@Observable
final class DictationService: NSObject {
    private(set) var isListening = false
    /// Live transcript = committed segments + the current in-flight partial.
    private(set) var transcript = ""
    private(set) var lastError: String?

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimerTask: Task<Void, Never>?

    /// Text finalized from prior request segments (SFSpeech caps each request at ~1 min, so we
    /// commit what we have and restart). The current partial is appended live for display.
    private var committed = ""
    private var currentPartial = ""

    private static let restartIntervalSeconds: UInt64 = 50

    override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.delegate = self
    }

    // MARK: - Permissions (mirrors VoiceCommandService)

    func requestAuthorization() async -> Bool {
        let speechGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speechGranted else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else { throw DictationError.recognizerUnavailable }
        committed = ""
        currentPartial = ""
        transcript = ""
        do {
            try configureAudioSession()
            try startRecognition()
        } catch {
            teardownRecognition()
            throw error
        }
        isListening = true
        lastError = nil
        scheduleRestartTimer()
    }

    /// Stop and return the final transcript.
    @discardableResult
    func stop() -> String {
        restartTimerTask?.cancel()
        restartTimerTask = nil
        commitPartial()
        teardownRecognition()
        isListening = false
        return transcript
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])
    }

    private func startRecognition() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // Build-66 guard: a 0-channel/0-rate format crashes installTap.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw DictationError.recognizerUnavailable
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.currentPartial = result.bestTranscription.formattedString
                    self.transcript = Self.join(self.committed, self.currentPartial)
                    if result.isFinal {
                        self.commitPartial()
                    }
                }
                if error != nil {
                    self.restartRecognition()
                }
            }
        }
    }

    /// Fold the current partial into committed text (segment boundary / restart / stop).
    private func commitPartial() {
        committed = Self.join(committed, currentPartial)
        currentPartial = ""
        transcript = committed
    }

    private func teardownRecognition() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }

    private func scheduleRestartTimer() {
        restartTimerTask?.cancel()
        restartTimerTask = Task { @MainActor [weak self] in
            while let self, self.isListening {
                try? await Task.sleep(nanoseconds: Self.restartIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled, self.isListening else { return }
                self.restartRecognition()
            }
        }
    }

    /// Restart the request (buffer limit or transient error), preserving the transcript so far.
    private func restartRecognition() {
        guard isListening else { return }
        commitPartial()
        teardownRecognition()
        do {
            try startRecognition()
        } catch {
            lastError = error.localizedDescription
            isListening = false
        }
    }

    /// Join two transcript fragments with a single separating space, trimming doubles.
    private static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}

extension DictationService: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in if !available { _ = self.stop() } }
    }
}

enum DictationError: LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition isn't available on this device right now."
        }
    }
}
