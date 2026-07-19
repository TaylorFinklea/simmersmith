import Foundation

/// Privacy-safe observations emitted while a cached household bootstrap is selected and
/// constructed. The payload is deliberately closed: it contains no account, household, record,
/// or user-authored values.
public enum HouseholdSyncBootstrapObservation: Equatable, Sendable {
    case checkpointSelected
    case bundleValidated(durationNanoseconds: UInt64)
    case bootstrapMaterialized(durationNanoseconds: UInt64, recordCount: Int)
    case storeMaterialized(durationNanoseconds: UInt64, recordCount: Int)
    case candidateGateOpened
    case candidateRejected(quarantined: Bool)
}

public typealias HouseholdSyncBootstrapObserver =
    @Sendable (HouseholdSyncBootstrapObservation) -> Void

public typealias HouseholdSyncMonotonicClock = @Sendable () -> UInt64

/// One closed observation context for a cached launch. The catalog carries this context on a
/// selected bootstrap so the engine cannot accidentally receive a different observer or clock.
public struct HouseholdSyncBootstrapObservationContext: Sendable {
    public let observer: HouseholdSyncBootstrapObserver?
    public let clock: HouseholdSyncMonotonicClock

    public init(
        observer: HouseholdSyncBootstrapObserver? = nil,
        clock: @escaping HouseholdSyncMonotonicClock = HouseholdSyncBootstrapObservationSupport.systemClock
    ) {
        self.observer = observer
        self.clock = clock
    }
}

public enum HouseholdSyncBootstrapObservationSupport {
    public static let systemClock: HouseholdSyncMonotonicClock = {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsed(
        since start: UInt64,
        clock: HouseholdSyncMonotonicClock
    ) -> UInt64 {
        let end = clock()
        return end >= start ? end - start : 0
    }
}
