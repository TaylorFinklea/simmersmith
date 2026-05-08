import AVFoundation
import Foundation
import Observation
import Speech

/// Hands-free voice commands for Cooking Mode. Uses
/// `SFSpeechRecognizer` with on-device recognition + an
/// `AVAudioEngine` tap so audio never leaves the phone.
///
/// SFSpeechRecognizer requests have a hard ~1-minute audio buffer
/// limit. We restart the request automatically every ~50 seconds and
/// also right after we recognize a keyword (to clear the buffer so
/// the same keyword does not re-fire on the next partial result).
enum VoiceCommand: String, Sendable {
    case next
    case previous
    case `repeat`
    case stop
}

@MainActor
@Observable
final class VoiceCommandService: NSObject {
    static let shared = VoiceCommandService()

    private(set) var isListening = false
    private(set) var lastHeard: String?
    private(set) var lastError: String?

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimerTask: Task<Void, Never>?

    private let continuation: AsyncStream<VoiceCommand>.Continuation
    let commands: AsyncStream<VoiceCommand>

    /// Restart the recognition request before SFSpeechRecognizer's
    /// ~1-minute buffer limit. 50s gives us comfortable margin.
    private static let restartIntervalSeconds: UInt64 = 50

    /// Words that trigger each command. Multiple aliases keep the
    /// recognition forgiving — "back" reads more naturally than
    /// "previous" mid-flow.
    private static let keywordMap: [String: VoiceCommand] = [
        "next": .next,
        "next step": .next,
        "previous": .previous,
        "back": .previous,
        "go back": .previous,
        "repeat": .repeat,
        "again": .repeat,
        "stop": .stop,
        "pause": .stop,
        "exit": .stop,
    ]

    override private init() {
        let (stream, cont) = AsyncStream<VoiceCommand>.makeStream()
        self.commands = stream
        self.continuation = cont
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.delegate = self
    }

    // MARK: - Permissions

    func requestAuthorization() async -> Bool {
        let speechGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else { return false }
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        return micGranted
    }

    // MARK: - Session lifecycle

    func start() throws {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceCommandError.recognizerUnavailable
        }
        do {
            try configureAudioSession()
            try startRecognition()
        } catch {
            // Best-effort cleanup so a half-started engine doesn't
            // leave the input route in a bad state for the next try.
            teardownRecognition()
            throw error
        }
        isListening = true
        lastError = nil
        scheduleRestartTimer()
    }

    func stop() {
        restartTimerTask?.cancel()
        restartTimerTask = nil
        teardownRecognition()
        isListening = false
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: [])
    }

    private func startRecognition() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Build 66 — `requiresOnDeviceRecognition = true` previously
        // crashed the app when the on-device model wasn't downloaded
        // yet. Prefer on-device when available but allow the server
        // path so the mic keeps working out of the box.
        if #available(iOS 13.0, *) {
            request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // Build 66 — guard against a 0-channel / 0-rate input format
        // (happens if the audio session category is wrong or the
        // route hasn't initialized). `installTap` crashes hard
        // when handed an invalid format.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw VoiceCommandError.recognizerUnavailable
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
                    let transcript = result.bestTranscription.formattedString
                    self.lastHeard = transcript
                    if let command = Self.matchCommand(in: transcript) {
                        self.continuation.yield(command)
                        self.restartRecognitionAfterKeyword()
                    }
                }
                if error != nil {
                    self.restartRecognitionAfterError()
                }
            }
        }
    }

    private func teardownRecognition() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func scheduleRestartTimer() {
        restartTimerTask?.cancel()
        restartTimerTask = Task { @MainActor [weak self] in
            while let self, self.isListening {
                try? await Task.sleep(nanoseconds: Self.restartIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled, self.isListening else { return }
                self.restartRecognitionForBufferLimit()
            }
        }
    }

    private func restartRecognitionAfterKeyword() {
        teardownRecognition()
        do {
            try startRecognition()
        } catch {
            lastError = error.localizedDescription
            isListening = false
        }
    }

    private func restartRecognitionAfterError() {
        guard isListening else { return }
        teardownRecognition()
        do {
            try startRecognition()
        } catch {
            lastError = error.localizedDescription
            isListening = false
        }
    }

    private func restartRecognitionForBufferLimit() {
        guard isListening else { return }
        teardownRecognition()
        do {
            try startRecognition()
        } catch {
            lastError = error.localizedDescription
            isListening = false
        }
    }

    // MARK: - Keyword matching

    /// Look for the latest keyword in the running transcript. We prefer
    /// matches near the tail of the transcript so older keywords don't
    /// re-fire before the buffer is restarted.
    private static func matchCommand(in transcript: String) -> VoiceCommand? {
        let lower = transcript.lowercased()
        let tail = lower.suffix(40)
        for (keyword, command) in keywordMap.sorted(by: { $0.key.count > $1.key.count }) {
            if tail.contains(keyword) {
                return command
            }
        }
        return nil
    }
}

extension VoiceCommandService: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            if !available { self.stop() }
        }
    }
}

enum VoiceCommandError: LocalizedError {
    case recognizerUnavailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device."
        case .authorizationDenied:
            return "SimmerSmith needs microphone and speech permissions to listen for voice commands."
        }
    }
}
