import BallastCore
import Foundation
import SimmerSmithKit

public struct BallastVoicePlanParser: Sendable {
    public enum ConfigurationError: Error, Sendable, Equatable {
        case providerMissingGuidedGeneration(String)
    }

    private let fmProvider: any LanguageProvider
    private let isFMAvailable: @Sendable () -> Bool
    private let cloudParse: @Sendable (String) async throws -> ParsedWeeklyPlan

    public init(
        fmProvider: any LanguageProvider,
        isFMAvailable: @escaping @Sendable () -> Bool,
        cloudParse: @escaping @Sendable (String) async throws -> ParsedWeeklyPlan
    ) {
        self.fmProvider = fmProvider
        self.isFMAvailable = isFMAvailable
        self.cloudParse = cloudParse
    }

    public func parse(transcript: String) async throws -> ParsedWeeklyPlan {
        try Task.checkCancellation()

        guard fmProvider.identity.capabilities.contains(.guidedGeneration) else {
            throw ConfigurationError.providerMissingGuidedGeneration(fmProvider.identity.name)
        }

        guard isFMAvailable() else {
            return try await runCloud(transcript)
        }

        let cancellation = CancellationSignal()
        let provider = CancellationTrackingProvider(provider: fmProvider, signal: cancellation)
        let generator = RepairingGenerator(
            provider: provider,
            budget: Budget(BudgetLimits(maxSteps: 3)),
            maxRepairs: 2
        )

        let outcome: AgentOutcome<WeeklyPlanWirePayload>
        do {
            outcome = try await generator.run(
                ParsedWeeklyPlanSchema(transcript: transcript),
                prompt: transcript,
                instructions: nil
            )
            try checkCancellation(cancellation)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BallastError where error.isBudgetExceeded {
            try checkCancellation(cancellation)
            return try await runCloud(transcript)
        }

        switch outcome {
        case .ok(let payload, _, _):
            return payload.toParsed()
        case .failed(let error, _, _):
            if Self.isConfigurationOrInvariantFailure(error) {
                throw error
            }
            return try await runCloud(transcript)
        }
    }

    private func runCloud(_ transcript: String) async throws -> ParsedWeeklyPlan {
        try Task.checkCancellation()
        return try await cloudParse(transcript)
    }

    private static func isConfigurationOrInvariantFailure(_ error: BallastError) -> Bool {
        switch error {
        case .unsupportedCapability, .toolFailed, .stepLimitExceeded:
            true
        default:
            false
        }
    }

    private func checkCancellation(_ signal: CancellationSignal) throws {
        if signal.wasCancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }
}

private struct CancellationTrackingProvider: LanguageProvider {
    let provider: any LanguageProvider
    let signal: CancellationSignal

    var identity: ProviderIdentity { provider.identity }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        do {
            return try await provider.generate(request)
        } catch is CancellationError {
            signal.markCancelled()
            throw CancellationError()
        }
    }
}

private final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
