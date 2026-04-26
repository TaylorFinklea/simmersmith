import AVFoundation
import Foundation
import Observation

/// Thin wrapper over AVSpeechSynthesizer used by Cooking Mode to read
/// step text aloud. Mute preference persists across launches via
/// UserDefaults. The cooking-mode view is the only caller, so the
/// audio session category is configured to .playback / .spokenAudio
/// here and Phase 3's voice-command service overrides it to
/// .playAndRecord when the mic is hot.
@MainActor
@Observable
final class SpokenStepService: NSObject {
    static let shared = SpokenStepService()

    private static let mutedDefaultsKey = "cooking.tts.muted"

    private let synth = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    var isMuted: Bool {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Self.mutedDefaultsKey)
            if isMuted { stop() }
        }
    }

    override private init() {
        self.isMuted = UserDefaults.standard.bool(forKey: Self.mutedDefaultsKey)
        super.init()
        synth.delegate = self
    }

    /// Configure the audio session so speech ducks background music.
    /// Safe to call repeatedly — AVAudioSession dedupes category changes.
    func activatePlaybackSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            // Audio session failures should not break the cook flow —
            // worst case is the user hears no TTS.
        }
    }

    func speak(_ text: String) {
        guard !isMuted else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }
}

extension SpokenStepService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
