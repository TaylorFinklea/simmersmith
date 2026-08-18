import Foundation
import AIProviderKit
import Testing

@testable import SimmerSmith

@MainActor
@Suite(.serialized)
struct AIDataSharingConsentTests {
    @Test func newProviderIsDeniedUntilGranted() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!store.hasConsent(for: "openai"))

        store.grant(for: "openai")

        #expect(store.hasConsent(for: "openai"))
    }

    @Test func grantIsIsolatedToOneProvider() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.grant(for: "openai")

        #expect(store.hasConsent(for: "openai"))
        #expect(!store.hasConsent(for: "gemini"))
    }

    @Test func revokeReturnsProviderToDenied() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.grant(for: "anthropic")

        store.revoke(for: "anthropic")

        #expect(!store.hasConsent(for: "anthropic"))
    }

    @Test func policyVersionChangeRequiresFreshConsent() {
        let suiteName = "AIDataSharingConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstPolicy = AIDataSharingConsentStore(defaults: defaults, policyVersion: 1)
        firstPolicy.grant(for: "ollama")

        let updatedPolicy = AIDataSharingConsentStore(defaults: defaults, policyVersion: 2)

        #expect(!updatedPolicy.hasConsent(for: "ollama"))
    }

    @Test func savedKeyCannotListModelsBeforeConsent() async {
        let fixture = makeService()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.keyStore.setKey("test-key", for: "openai")

        await #expect(throws: AIServiceError.dataSharingConsentRequired("openai")) {
            try await fixture.service.listModels(for: "openai")
        }
    }

    @Test func clearingKeyAlsoRevokesConsent() {
        let fixture = makeService()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.keyStore.setKey("test-key", for: "anthropic")
        fixture.service.grantDataSharingConsent(for: "anthropic")

        fixture.service.clearKey(for: "anthropic")

        #expect(fixture.keyStore.key(for: "anthropic") == nil)
        #expect(!fixture.service.hasDataSharingConsent(for: "anthropic"))
    }

    @Test func savingNewKeyRequiresFreshConsent() {
        let fixture = makeService()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.service.grantDataSharingConsent(for: "openai")

        fixture.service.saveKey("replacement-key", for: "openai")

        #expect(fixture.keyStore.key(for: "openai") == "replacement-key")
        #expect(!fixture.service.hasDataSharingConsent(for: "openai"))
    }

    @Test func imageFailoverCannotUseUnapprovedGemini() async {
        let fixture = makeImageService(grantGemini: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let expected = AIError.imageGenFailed(
            provider: "openai",
            transient: true,
            detail: "temporary failure"
        )

        await #expect(throws: expected) {
            try await fixture.service.generateRecipeImage(name: "Soup")
        }
    }

    @Test func imageFailoverCanUseSeparatelyApprovedGemini() async throws {
        let fixture = makeImageService(grantGemini: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let (data, mimeType) = try await fixture.service.generateRecipeImage(name: "Soup")

        #expect(data == Data([0x47]))
        #expect(mimeType == "image/png")
    }

    private func makeStore() -> (AIDataSharingConsentStore, UserDefaults, String) {
        let suiteName = "AIDataSharingConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (AIDataSharingConsentStore(defaults: defaults, policyVersion: 1), defaults, suiteName)
    }

    private func makeService() -> (
        service: AIService,
        keyStore: InMemoryKeyStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "AIDataSharingConsentServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let consentStore = AIDataSharingConsentStore(defaults: defaults, policyVersion: 1)
        let keyStore = InMemoryKeyStore()
        let session = HouseholdSession(householdID: suiteName)
        return (
            AIService(keyStore: keyStore, consentStore: consentStore, session: session),
            keyStore,
            defaults,
            suiteName
        )
    }

    private func makeImageService(grantGemini: Bool) -> (
        service: AIService,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "AIDataSharingImageConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let consentStore = AIDataSharingConsentStore(defaults: defaults, policyVersion: 1)
        let keyStore = InMemoryKeyStore()
        keyStore.setKey("openai-key", for: "openai")
        keyStore.setKey("gemini-key", for: "gemini")
        consentStore.grant(for: "openai")
        if grantGemini { consentStore.grant(for: "gemini") }
        let session = HouseholdSession(householdID: suiteName)
        return (
            AIService(
                keyStore: keyStore,
                consentStore: consentStore,
                imageGenerator: ConsentFailoverImageGenerator(),
                imageProviderResolver: { .openAI },
                session: session
            ),
            defaults,
            suiteName
        )
    }
}

@MainActor
private struct ConsentFailoverImageGenerator: RecipeImageGenerating {
    func generateImage(
        prompt: String,
        provider: ImageProvider,
        model: String?,
        key: String
    ) async throws -> (Data, String) {
        switch provider {
        case .openAI:
            throw AIError.imageGenFailed(
                provider: "openai",
                transient: true,
                detail: "temporary failure"
            )
        case .gemini:
            return (Data([0x47]), "image/png")
        }
    }
}
