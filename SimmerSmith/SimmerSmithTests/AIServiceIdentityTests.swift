import Foundation
import Testing
import AIProviderKit

@testable import SimmerSmith

// P8 D2 — AIService identity snapshot + per-call identity lease.
//
// These exercise the pure helpers directly (`AIService.identity(for:...)`,
// `AIService.checkIdentityLease`) rather than a full `generate()` call:
// `resolveConfiguration()` needs a live `HouseholdSession.privateStore`, which only
// exists after `HouseholdSession.start()` succeeds against a real iCloud account — not
// constructible in this app-hosted suite. No other test in this target calls `.start()`
// either (see IngredientRepositoryTests etc.), which instead build a standalone
// `PrivatePlaneStore` when they need private-plane state.
@MainActor
struct AIServiceIdentityTests {

    // MARK: - Snapshot format (pinned: providerName ∈ openai|anthropic|openmodels/<vendor-id>)

    @Test
    func identityFormatsOpenAI() {
        let identity = AIService.identity(
            for: .openAI, openAIModel: "gpt-4o", anthropicModel: "claude-opus-4-5", openModelsModel: ""
        )
        #expect(identity.providerName == "openai")
        #expect(identity.modelIdentifier == "gpt-4o")
    }

    @Test
    func identityFormatsAnthropic() {
        let identity = AIService.identity(
            for: .anthropic, openAIModel: "gpt-4o", anthropicModel: "claude-opus-4-5", openModelsModel: ""
        )
        #expect(identity.providerName == "anthropic")
        #expect(identity.modelIdentifier == "claude-opus-4-5")
    }

    @Test
    func identityFormatsOpenModelsWithExplicitModel() {
        let identity = AIService.identity(
            for: .openModels(.neuralwatt), openAIModel: "", anthropicModel: "", openModelsModel: "glm-5.2-fast"
        )
        #expect(identity.providerName == "openmodels/neuralwatt")
        #expect(identity.modelIdentifier == "glm-5.2-fast")
    }

    @Test
    func identityFormatsOpenModelsFallsBackToVendorDefaultWhenModelIsEmpty() {
        let identity = AIService.identity(
            for: .openModels(.ollamaCloud), openAIModel: "", anthropicModel: "", openModelsModel: ""
        )
        #expect(identity.providerName == "openmodels/ollama")
        #expect(identity.modelIdentifier == ProviderRegistry.descriptor(for: .ollamaCloud).defaultModel)
    }

    // MARK: - Lease check: inert by default (nil lease always passes)

    @Test
    func leaseCheckPassesWhenNoLeaseIsHeld() throws {
        let resolved = AIServiceIdentity(providerName: "openai", modelIdentifier: "gpt-4o")
        // Any resolved identity — including one a plausible engaged lease would reject —
        // must pass when no lease is held. This is the "inert by default" property.
        try AIService.checkIdentityLease(nil, resolved: resolved)
    }

    // MARK: - Lease check: abort on violation

    @Test
    func leaseCheckPassesWhenResolvedMatchesLease() throws {
        let identity = AIServiceIdentity(providerName: "anthropic", modelIdentifier: "claude-opus-4-5")
        try AIService.checkIdentityLease(identity, resolved: identity)
    }

    @Test
    func leaseCheckThrowsOnProviderMismatch() {
        let leased = AIServiceIdentity(providerName: "openai", modelIdentifier: "gpt-4o")
        let resolved = AIServiceIdentity(providerName: "anthropic", modelIdentifier: "claude-opus-4-5")
        #expect(throws: AIServiceError.identityLeaseViolation(expected: leased, resolved: resolved)) {
            try AIService.checkIdentityLease(leased, resolved: resolved)
        }
    }

    @Test
    func leaseCheckThrowsOnModelMismatchWithinSameProvider() {
        let leased = AIServiceIdentity(providerName: "openai", modelIdentifier: "gpt-4o")
        let resolved = AIServiceIdentity(providerName: "openai", modelIdentifier: "gpt-5")
        #expect(throws: AIServiceError.identityLeaseViolation(expected: leased, resolved: resolved)) {
            try AIService.checkIdentityLease(leased, resolved: resolved)
        }
    }

    // MARK: - Lease lifecycle: single ownership + idempotent release

    @Test
    func beginIdentityLeaseThrowsOnDoubleEngagement() throws {
        // Constructing HouseholdSession/AIService touches no network — mirrors every
        // other test in this target that builds a session without calling `.start()`.
        let session = HouseholdSession(householdID: "ai-identity-lease-\(UUID().uuidString)")
        let service = AIService(session: session)
        let first = AIServiceIdentity(providerName: "openai", modelIdentifier: "gpt-4o")
        let second = AIServiceIdentity(providerName: "anthropic", modelIdentifier: "claude-opus-4-5")

        try service.beginIdentityLease(first)
        #expect(throws: AIServiceError.identityLeaseAlreadyHeld) {
            try service.beginIdentityLease(second)
        }
        service.endIdentityLease()
    }

    @Test
    func endIdentityLeaseIsIdempotentWhenNeverEngaged() {
        let session = HouseholdSession(householdID: "ai-identity-lease-idempotent-\(UUID().uuidString)")
        let service = AIService(session: session)
        service.endIdentityLease()
        service.endIdentityLease()
    }

    @Test
    func leaseCanBeReEngagedAfterRelease() throws {
        let session = HouseholdSession(householdID: "ai-identity-lease-reengage-\(UUID().uuidString)")
        let service = AIService(session: session)
        let identity = AIServiceIdentity(providerName: "openai", modelIdentifier: "gpt-4o")

        try service.beginIdentityLease(identity)
        service.endIdentityLease()
        try service.beginIdentityLease(identity)
        service.endIdentityLease()
    }
}
