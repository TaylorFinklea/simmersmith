import Foundation
import Testing
@testable import SimmerSmithKit

// V-T4 — the availability decision table. Every parse-availability × asset × key combination
// resolves to a defined (parseSource, transcribeEngine), and the feature never silently
// dead-ends (ineligible + no key → .unavailable, surfaced as a CTA, not a broken button).

@Test("on-device parse when the model is available, regardless of cloud key")
func onDeviceWhenAvailable() {
    for hasKey in [true, false] {
        let p = VoicePlanningAvailability.plan(parse: .available, transcriberAssetInstalled: true, hasCloudKey: hasKey)
        #expect(p.parseSource == .onDevice)
        #expect(p.canParse)
    }
}

@Test("ineligible/unenabled/not-ready fall back to cloud when a key exists")
func cloudWhenIneligibleWithKey() {
    for reason in [ParseAvailability.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady] {
        let p = VoicePlanningAvailability.plan(parse: reason, transcriberAssetInstalled: false, hasCloudKey: true)
        #expect(p.parseSource == .cloud)
        #expect(p.canParse)
    }
}

@Test("ineligible + no key → unavailable (the set-up-AI CTA case, never silent)")
func unavailableWhenNoPath() {
    for reason in [ParseAvailability.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady] {
        let p = VoicePlanningAvailability.plan(parse: reason, transcriberAssetInstalled: true, hasCloudKey: false)
        #expect(p.parseSource == .unavailable)
        #expect(!p.canParse)
    }
}

@Test("transcribe engine tracks asset state, independent of parse source")
func transcribeEngineByAsset() {
    let installed = VoicePlanningAvailability.plan(parse: .available, transcriberAssetInstalled: true, hasCloudKey: false)
    #expect(installed.transcribeEngine == .speechTranscriber)
    let missing = VoicePlanningAvailability.plan(parse: .available, transcriberAssetInstalled: false, hasCloudKey: false)
    #expect(missing.transcribeEngine == .sfSpeech)
}
