import Foundation
import Observation
import OSLog
import SwiftData
import UserNotifications
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import HouseholdSync
#endif

#if canImport(CloudKit)
enum CacheFirstGateSource: Equatable, Sendable {
    case staticDefault
    case debug
    case sandboxReceipt
    case appStoreReceipt
    case installOverride
    case unknown
    case testOverride
}

enum HouseholdInitialProjection: String, CaseIterable, Equatable, Sendable {
    case recipe
    case metadata
    case week
    case ingredient
    case guest
    case event
    case pantry
    case alias
}

enum LaunchObservationEventKind: String, Equatable, Sendable {
    case launchTaskStarted = "launch_task_started"
}

enum LaunchObservationEvent: Equatable, Sendable {
    case launchTaskStarted
    case accountIdentityResolved
    case cacheFirstGate(source: CacheFirstGateSource, decision: Bool)
    case bootstrap(HouseholdSyncBootstrapObservation)
    case householdProjectionReady(
        HouseholdInitialProjection,
        durationNanoseconds: UInt64,
        recordCount: Int
    )
    case householdProjectionsReady
    case mainTabVisible
    case privatePlaneReady
    case reconciliationComplete(success: Bool, durationNanoseconds: UInt64)
}

enum LaunchObservationPayloadField: Equatable, Sendable {
    case durationNanoseconds(UInt64)
    case count(Int)
    case boolean(Bool)
    case build(String)
    case sdkVersion(String)
    case accountName(String)
    case householdID(String)
    case recipeText(String)
    case rawRecordID(String)
    case hashedID(String)
}

struct LaunchObservationPayload: Equatable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case disallowedField
        case negativeCount
        case disallowedKind
    }

    let kind: String
    let fields: [LaunchObservationPayloadField]

    static func validate(
        kind: String,
        fields: [LaunchObservationPayloadField]
    ) -> Result<LaunchObservationPayload, ValidationError> {
        let allowedKinds: Set<String> = [
            "launch_task_started", "account_identity_resolved",
            "cache_gate_static_default", "cache_gate_debug", "cache_gate_sandbox",
            "cache_gate_app_store", "cache_gate_override", "cache_gate_unknown",
            "bootstrap_checkpoint_selected", "bootstrap_bundle_validated",
            "bootstrap_materialized", "bootstrap_store_materialized", "bootstrap_gate_opened",
            "bootstrap_candidate_rejected",
            "projection_ready_recipe", "projection_ready_metadata", "projection_ready_week",
            "projection_ready_ingredient", "projection_ready_guest", "projection_ready_event",
            "projection_ready_pantry", "projection_ready_alias", "projections_ready",
            "main_tab_visible", "private_plane_ready", "reconciliation_complete",
        ]
        guard allowedKinds.contains(kind) else { return .failure(.disallowedKind) }
        for field in fields {
            switch field {
            case .durationNanoseconds:
                continue
            case .count(let count):
                guard count >= 0 else { return .failure(.negativeCount) }
            case .boolean, .build, .sdkVersion:
                continue
            case .accountName, .householdID, .recipeText, .rawRecordID, .hashedID:
                return .failure(.disallowedField)
            }
        }
        return .success(Self(kind: kind, fields: fields))
    }

    static func validate(
        kind: LaunchObservationEventKind,
        fields: [LaunchObservationPayloadField]
    ) -> Result<LaunchObservationPayload, ValidationError> {
        validate(kind: kind.rawValue, fields: fields)
    }

    var rendered: String {
        fields.compactMap { field in
            switch field {
            case .durationNanoseconds(let value): return "duration_ns=\(value)"
            case .count(let value): return "count=\(value)"
            case .boolean(let value): return "bool=\(value ? 1 : 0)"
            case .build(let value): return "build=\(value)"
            case .sdkVersion(let value): return "sdk=\(value)"
            case .accountName, .householdID, .recipeText, .rawRecordID, .hashedID:
                return nil
            }
        }.joined(separator: " ")
    }
}

private final class OSLogLaunchObservationSink: @unchecked Sendable {
    private let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "app.simmersmith.ios", category: "Launch")

    func append(_ payload: LaunchObservationPayload) {
        guard case .success = LaunchObservationPayload.validate(kind: payload.kind, fields: payload.fields) else {
            return
        }
        let message = payload.rendered
        switch payload.kind {
        case "launch_task_started": os_signpost(.event, log: log, name: "launch_task_started", "%{public}s", message)
        case "account_identity_resolved": os_signpost(.event, log: log, name: "account_identity_resolved", "%{public}s", message)
        case "cache_gate_static_default": os_signpost(.event, log: log, name: "cache_gate_static_default", "%{public}s", message)
        case "cache_gate_debug": os_signpost(.event, log: log, name: "cache_gate_debug", "%{public}s", message)
        case "cache_gate_sandbox": os_signpost(.event, log: log, name: "cache_gate_sandbox", "%{public}s", message)
        case "cache_gate_app_store": os_signpost(.event, log: log, name: "cache_gate_app_store", "%{public}s", message)
        case "cache_gate_override": os_signpost(.event, log: log, name: "cache_gate_override", "%{public}s", message)
        case "cache_gate_unknown": os_signpost(.event, log: log, name: "cache_gate_unknown", "%{public}s", message)
        case "bootstrap_checkpoint_selected": os_signpost(.event, log: log, name: "bootstrap_checkpoint_selected", "%{public}s", message)
        case "bootstrap_bundle_validated": os_signpost(.event, log: log, name: "bootstrap_bundle_validated", "%{public}s", message)
        case "bootstrap_materialized": os_signpost(.event, log: log, name: "bootstrap_materialized", "%{public}s", message)
        case "bootstrap_store_materialized": os_signpost(.event, log: log, name: "bootstrap_store_materialized", "%{public}s", message)
        case "bootstrap_gate_opened": os_signpost(.event, log: log, name: "bootstrap_gate_opened", "%{public}s", message)
        case "bootstrap_candidate_rejected": os_signpost(.event, log: log, name: "bootstrap_candidate_rejected", "%{public}s", message)
        case "projection_ready_recipe": os_signpost(.event, log: log, name: "projection_ready_recipe", "%{public}s", message)
        case "projection_ready_metadata": os_signpost(.event, log: log, name: "projection_ready_metadata", "%{public}s", message)
        case "projection_ready_week": os_signpost(.event, log: log, name: "projection_ready_week", "%{public}s", message)
        case "projection_ready_ingredient": os_signpost(.event, log: log, name: "projection_ready_ingredient", "%{public}s", message)
        case "projection_ready_guest": os_signpost(.event, log: log, name: "projection_ready_guest", "%{public}s", message)
        case "projection_ready_event": os_signpost(.event, log: log, name: "projection_ready_event", "%{public}s", message)
        case "projection_ready_pantry": os_signpost(.event, log: log, name: "projection_ready_pantry", "%{public}s", message)
        case "projection_ready_alias": os_signpost(.event, log: log, name: "projection_ready_alias", "%{public}s", message)
        case "projections_ready": os_signpost(.event, log: log, name: "projections_ready", "%{public}s", message)
        case "main_tab_visible": os_signpost(.event, log: log, name: "main_tab_visible", "%{public}s", message)
        case "private_plane_ready": os_signpost(.event, log: log, name: "private_plane_ready", "%{public}s", message)
        case "reconciliation_complete": os_signpost(.event, log: log, name: "reconciliation_complete", "%{public}s", message)
        default: return
        }
    }
}

final class LaunchObservationRecorder: @unchecked Sendable {
    typealias Clock = @Sendable () -> UInt64
    typealias Sink = @Sendable (LaunchObservationEvent) -> Void

    private let sink: Sink
    let clock: Clock
    private let build: String
    private let sdkVersion: String
    private let lock = NSLock()
    private var onceKeys: Set<String> = []
    private static let productionSink = OSLogLaunchObservationSink()

    init(
        sink: @escaping Sink = LaunchObservationRecorder.defaultSink,
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        sdkVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.sink = sink
        self.clock = clock
        self.build = build
        self.sdkVersion = sdkVersion
    }

    static let defaultSink: Sink = { event in
        let payload = makePayload(for: event, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", sdkVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        guard case .success(let payload) = LaunchObservationPayload.validate(kind: payload.kind, fields: payload.fields) else { return }
        productionSink.append(payload)
    }

    func record(_ event: LaunchObservationEvent) {
        let payload = Self.makePayload(for: event, build: build, sdkVersion: sdkVersion)
        guard case .success = LaunchObservationPayload.validate(kind: payload.kind, fields: payload.fields) else { return }
        sink(event)
    }

    func recordLaunchTaskStarted() { recordOnce(.launchTaskStarted, key: "launch") }
    func recordAccountIdentityResolved() { recordOnce(.accountIdentityResolved, key: "identity") }
    func recordCacheFirstGate(source: CacheFirstGateSource, decision: Bool) {
        recordOnce(.cacheFirstGate(source: source, decision: decision), key: "gate")
    }
    func recordBootstrap(_ observation: HouseholdSyncBootstrapObservation) {
        record(.bootstrap(observation))
    }
    func recordMainTabVisible() { recordOnce(.mainTabVisible, key: "main_tab") }
    func recordPrivatePlaneReady() { record(.privatePlaneReady) }
    func recordHouseholdProjectionsReady() { record(.householdProjectionsReady) }
    func recordReconciliationComplete(success: Bool, durationNanoseconds: UInt64) {
        record(.reconciliationComplete(success: success, durationNanoseconds: durationNanoseconds))
    }

    func recordProjection(
        _ projection: HouseholdInitialProjection,
        operation: () -> Int
    ) -> Int {
        let start = clock()
        let count = operation()
        let duration = elapsed(since: start)
        record(.householdProjectionReady(
            projection,
            durationNanoseconds: duration,
            recordCount: count))
        return count
    }

    private func recordOnce(_ event: LaunchObservationEvent, key: String) {
        let shouldRecord = lock.withLock { onceKeys.insert(key).inserted }
        if shouldRecord { record(event) }
    }

    private func elapsed(since start: UInt64) -> UInt64 {
        let end = clock()
        return end >= start ? end - start : 0
    }

    static func makePayload(
        for event: LaunchObservationEvent,
        build: String,
        sdkVersion: String
    ) -> LaunchObservationPayload {
        let common: [LaunchObservationPayloadField] = [.build(build), .sdkVersion(sdkVersion)]
        switch event {
        case .launchTaskStarted:
            return LaunchObservationPayload(kind: "launch_task_started", fields: common)
        case .accountIdentityResolved:
            return LaunchObservationPayload(kind: "account_identity_resolved", fields: common)
        case .cacheFirstGate(let source, let decision):
            let kind: String
            switch source {
            case .staticDefault: kind = "cache_gate_static_default"
            case .debug: kind = "cache_gate_debug"
            case .sandboxReceipt: kind = "cache_gate_sandbox"
            case .appStoreReceipt: kind = "cache_gate_app_store"
            case .installOverride, .testOverride: kind = "cache_gate_override"
            case .unknown: kind = "cache_gate_unknown"
            }
            return LaunchObservationPayload(kind: kind, fields: common + [.boolean(decision)])
        case .bootstrap(let observation):
            switch observation {
            case .checkpointSelected:
                return LaunchObservationPayload(kind: "bootstrap_checkpoint_selected", fields: common)
            case .bundleValidated(let duration):
                return LaunchObservationPayload(kind: "bootstrap_bundle_validated", fields: common + [.durationNanoseconds(duration)])
            case .bootstrapMaterialized(let duration, let count):
                return LaunchObservationPayload(kind: "bootstrap_materialized", fields: common + [.durationNanoseconds(duration), .count(max(0, count))])
            case .storeMaterialized(let duration, let count):
                return LaunchObservationPayload(kind: "bootstrap_store_materialized", fields: common + [.durationNanoseconds(duration), .count(max(0, count))])
            case .candidateGateOpened:
                return LaunchObservationPayload(kind: "bootstrap_gate_opened", fields: common)
            case .candidateRejected(let quarantined):
                return LaunchObservationPayload(kind: "bootstrap_candidate_rejected", fields: common + [.boolean(quarantined)])
            }
        case .householdProjectionReady(let projection, let duration, let count):
            return LaunchObservationPayload(
                kind: "projection_ready_\(projection.rawValue)",
                fields: common + [.durationNanoseconds(duration), .count(max(0, count))])
        case .householdProjectionsReady:
            return LaunchObservationPayload(kind: "projections_ready", fields: common)
        case .mainTabVisible:
            return LaunchObservationPayload(kind: "main_tab_visible", fields: common)
        case .privatePlaneReady:
            return LaunchObservationPayload(kind: "private_plane_ready", fields: common)
        case .reconciliationComplete(let success, let duration):
            return LaunchObservationPayload(kind: "reconciliation_complete", fields: common + [.durationNanoseconds(duration), .boolean(success)])
        }
    }
}

private func makePayload(
    for event: LaunchObservationEvent,
    build: String,
    sdkVersion: String
) -> LaunchObservationPayload {
    LaunchObservationRecorder.makePayload(for: event, build: build, sdkVersion: sdkVersion)
}
#endif

#if canImport(CloudKit)
/// The app's external async boundaries for authoritative household system work.
/// Production uses `live`; tests use this same boundary to make a continuation suspend.
struct HouseholdSystemOperationExecutor {
    struct ZoneWideShare {
        let share: CKShare
        let container: CKContainer
    }

    let saveCurrentWeekCarryOver: @MainActor (
        _ repository: WeekRepository,
        _ groceryRepository: GroceryRepository?,
        _ weekID: String,
        _ meals: [MealUpdateRequest],
        _ knownMealIDs: Set<String>
    ) async throws -> WeekSnapshot?
    let fetchChanges: @MainActor (_ session: HouseholdSession) async throws -> Void
    let drainChanges: @MainActor (_ session: HouseholdSession, _ maxPasses: Int) async throws -> Void
    let prepareZoneWideShare: @MainActor (
        _ householdID: String,
        _ title: String
    ) async throws -> ZoneWideShare

    @MainActor static let live = Self(
        saveCurrentWeekCarryOver: { repository, groceryRepository, weekID, meals, knownMealIDs in
            guard let snapshot = try repository.saveWeekMeals(
                weekID: weekID,
                meals: meals,
                knownMealIDs: knownMealIDs
            ) else { return nil }
            let groceryResult = groceryRepository?.regenerate(weekID: weekID) ?? .allowed
            guard groceryResult == .allowed else { throw groceryResult }
            return snapshot
        },
        fetchChanges: { session in
            try await session.engine.fetchChanges()
        },
        drainChanges: { session, maxPasses in
            try await session.engine.sendUntilDrained(maxPasses: maxPasses)
        },
        prepareZoneWideShare: { householdID, title in
            let flow = HouseholdShareFlow()
            let share = try await flow.makeOrFetchZoneWideShare(
                householdID: householdID,
                title: title
            )
            return ZoneWideShare(share: share, container: flow.container)
        }
    )
}

/// App-owned lifecycle disk locations. The transaction and marker files deliberately live
/// beside, never inside, the shadow root so a whole-root retirement cannot erase pending work.
struct HouseholdLifecyclePaths: Equatable {
    let directory: URL

    var transactionURL: URL { directory.appendingPathComponent("lifecycle-transaction.json") }
    var participantMarkerURL: URL { directory.appendingPathComponent("participant-marker.json") }
    var factoryResetImportMarkerURL: URL {
        directory.appendingPathComponent("factory-reset-needs-import")
    }
    var shadowRootURL: URL { directory.appendingPathComponent("shadow-mirror", isDirectory: true) }

    static func live(directoryOverride: URL? = nil) -> Self {
        if let directoryOverride { return Self(directory: directoryOverride) }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return Self(directory: appSupport.appendingPathComponent("HouseholdSync", isDirectory: true))
    }
}

/// All filesystem and remote deletion seams used by lifecycle replay. Tests replace these with
/// deterministic closures; production keeps package-owned namespace invalidation primitives.
struct HouseholdLifecycleExecutor {
    let currentAccountRecordName: @MainActor () async throws -> String?
    let requestRootClear: (URL) throws -> Void
    let completeRootClear: (URL) throws -> Void
    let requestScopeClear: (MirrorScope, URL) throws -> Void
    let completeScopeClear: (MirrorScope, URL) throws -> Void
    let clearRoleEngineStateFiles: (URL) throws -> Void
    let deleteAllHouseholdZones: @MainActor (_ expectedAccountRecordName: String) async throws -> [String]

    @MainActor static let live = Self(
        currentAccountRecordName: {
            try await HouseholdShareFlow().currentUserRecordName()
        },
        requestRootClear: { try ShadowMirrorCheckpointWriter.requestRootClearSynchronously($0) },
        completeRootClear: { try ShadowMirrorCheckpointWriter.completeRootClearSynchronously($0) },
        requestScopeClear: {
            try ShadowMirrorCheckpointWriter.requestScopeClearSynchronously($0, rootDirectory: $1)
        },
        completeScopeClear: {
            try ShadowMirrorCheckpointWriter.completeScopeClearSynchronously($0, rootDirectory: $1)
        },
        clearRoleEngineStateFiles: { directory in
            let fileManager = FileManager.default
            for name in ["engine-state.json", "engine-state-shared.json"] {
                let url = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
            try DurableLifecycleFileSupport.synchronize(directory)
        },
        deleteAllHouseholdZones: { expectedAccountRecordName in
            try await HouseholdZoneProvisioner().deleteAllHouseholdZones(
                expectedAccountRecordName: expectedAccountRecordName)
        })
}

enum HouseholdLifecycleGateState: Equatable {
    case absent
    case pending(HouseholdLifecycleTransaction)
    case malformed
}

enum HouseholdLifecycleReplayOutcome: Equatable {
    case accountBoundary
    case participantRevocation
    case unexpectedOwnerZoneDeletion
    case factoryResetNeedsImport
}
#endif

@MainActor
@Observable
final class AppState {
    enum MainTab: Hashable {
        case week
        case grocery
        case recipes
        case events
        case assistant
        case settings
    }

    enum SyncPhase: Equatable {
        case idle
        case loading
        case synced(Date)
        case offline
        case failed(String)
    }

    struct AssistantDeltaEvent: Decodable {
        let messageId: String
        let delta: String
    }

    struct AssistantRecipeDraftEvent: Decodable {
        let messageId: String
        let draft: RecipeDraft
    }

    struct AssistantErrorEvent: Decodable {
        let messageId: String
        let detail: String
    }

    struct AssistantWeekUpdatedEvent: Decodable {
        let week: WeekSnapshot
    }

    /// Server-emitted "still working" tick during long single-shot tool
    /// runs (e.g. `generate_week_plan`). Keeps the SSE connection alive
    /// against edge idle-timeouts and carries elapsed time so the UI can
    /// annotate the spinner instead of feeling like a hang.
    struct AssistantHeartbeatEvent: Decodable {
        let messageId: String
        let elapsedSeconds: Int
    }

    let settingsStore: ConnectionSettingsStore
    let cacheStore: SimmerSmithCacheStore
    let apiClient: SimmerSmithAPIClient
    let subscriptionStore = SubscriptionStore()

    // SP-C Task 5 — CloudKit data plane. Constructed after sign-in once the
    // household ID is known (from the Fly household snapshot), torn down on
    // sign-out. nil before sign-in. Guarded by canImport(CloudKit) so the
    // app target still compiles on platforms without CloudKit.
    #if canImport(CloudKit)
    @ObservationIgnored var householdSession: HouseholdSession?
    @ObservationIgnored let launchObservationRecorder: LaunchObservationRecorder
    /// Session currently inside the serialized construction/start path. Lifecycle callbacks are
    /// installed before its first await, so the epoch-first choke point must be able to revoke
    /// this candidate even before repository wiring publishes it as `householdSession`.
    @ObservationIgnored var bootingHouseholdSession: HouseholdSession?
    /// Lifecycle relays whose first event already triggered teardown remain eligible to deliver
    /// a later stronger account boundary after their Session has been released.
    @ObservationIgnored var acceptedRetiredLifecycleSourceIDs: Set<UUID> = []
    @ObservationIgnored var recipeRepository: RecipeRepository?
    @ObservationIgnored var metadataRepository: MetadataRepository?
    // SP-C slice 3: week + grocery CloudKit repos.
    @ObservationIgnored var weekRepository: WeekRepository?
    @ObservationIgnored var groceryRepository: GroceryRepository?
    @ObservationIgnored var ingredientRepository: IngredientRepository?
    // SP-C slice 4: event + guest CloudKit repos.
    @ObservationIgnored var eventRepository: EventRepository?
    @ObservationIgnored var guestRepository: GuestRepository?
    // SP-C slice 5: per-user PRIVATE-plane repos (NSPCKC, not the household zone).
    @ObservationIgnored var profileRepository: ProfileRepository?
    @ObservationIgnored var preferenceRepository: PreferenceRepository?
    // SP-C slice 5: household-zone pantry + alias repos.
    @ObservationIgnored var pantryRepository: PantryRepository?
    @ObservationIgnored var aliasRepository: AliasRepository?
    // SP-C AI-1: the single AI call seam. Constructed alongside profileRepository
    // once the CloudKit session is live. API keys live in Keychain; provider/model
    // config in the private plane. nil before the session is ready.
    @ObservationIgnored var aiService: AIService?
    // SP-C AI-5: private-plane assistant conversation storage. Constructed alongside
    // profileRepository once the CloudKit session is live. nil before the session is ready.
    @ObservationIgnored var assistantRepository: AssistantRepository?
    @ObservationIgnored var householdSystemOperationExecutor = HouseholdSystemOperationExecutor.live
    @ObservationIgnored let householdLifecyclePaths: HouseholdLifecyclePaths
    @ObservationIgnored let householdLifecycleTransactionStore: HouseholdLifecycleTransactionStore
    @ObservationIgnored let participantMarkerStore: ParticipantMarkerStore
    @ObservationIgnored let factoryResetImportMarkerStore: DurableLifecycleFlagStore
    @ObservationIgnored var householdLifecycleExecutor = HouseholdLifecycleExecutor.live
    /// Serializes every household-session boot (owner ensure + share-accept adopt) into a
    /// strict FIFO so the two independent entry points (`ensureHouseholdSession` and
    /// `processPendingShare`) never interleave at suspension points (simmersmith-0gf). Each
    /// queued op re-checks `householdSession` after its predecessors finish, so no separate
    /// dedup/clear bookkeeping is needed.
    @ObservationIgnored let sessionBootQueue = SerialTaskQueue()
    /// Bumped by `teardownHouseholdSession()` on every sign-out / factory-reset
    /// (simmersmith-0gf blocking-finding fix). `sessionBootQueue` is never drained on
    /// sign-out, so a boot op that was already queued (or mid-flight) behind an in-flight
    /// predecessor can otherwise dequeue AFTER a teardown and silently re-wire a session the
    /// user just tore down. Each boot entry point captures this epoch when the request is
    /// made; the op re-checks it immediately before publishing `householdSession` (and once
    /// more right after dequeuing, before doing any work) and aborts — detaching anything it
    /// already built — if the epoch has moved on.
    @ObservationIgnored var sessionBootEpoch: Int = 0
    /// An owner-to-participant handoff retains only the parked owner session when durable
    /// parking failed. No participant successor may be constructed until this same writer
    /// successfully persists the parking marker.
    @ObservationIgnored var pendingAdoptionParkingSession: HouseholdSession?
    // simmersmith-qrt: engine-level sync visibility (failed saves, pending count,
    // participant-join progress). Constructed eagerly (no household-id dependency) so
    // Settings/the main-UI banner can read it before a session boots. `@ObservationIgnored`
    // mirrors the repositories above — it's `@Observable` itself and drives its own updates.
    @ObservationIgnored let syncStatusCenter = SyncStatusCenter()

    /// An authority-only continuation may publish only while its captured session is still the
    /// app's live session for the same boot epoch.
    func isCurrentAuthoritativeHouseholdSession(
        _ session: HouseholdSession,
        requestEpoch: Int
    ) -> Bool {
        sessionBootEpoch == requestEpoch &&
            householdSession === session &&
            session.hasCurrentAuthority
    }
    #endif
    @ObservationIgnored private lazy var _assistantCoordinator: AIAssistantCoordinator = AIAssistantCoordinator(appState: self)
    var assistantCoordinator: AIAssistantCoordinator { _assistantCoordinator }
    var pendingPaywall: PaywallReason?
    /// simmersmith-224: release notes awaiting their once-per-update showing.
    /// Set by `evaluatePendingReleaseNotes()` once the household is ready;
    /// cleared when the sheet is dismissed. See `AppState+ReleaseNotes`.
    var pendingReleaseNotes: ReleaseNotesPresentation?

    // Tracks the refresh task started by clearLocalCache() so that a
    // follow-up resetConnection() can cancel it before it races with the
    // cleared connection state.
    var postClearRefreshTask: Task<Void, Never>?

    var serverURLDraft: String
    var authTokenDraft: String
    var aiProviderModeDraft: String = "auto"
    /// User-typed region used for in-season produce (M12 Phase 3).
    /// Free text — the AI infers state/country. Empty = generic US.
    var userRegionDraft: String = ""
    /// Per-user image-gen provider (M17). `"openai"` (default) or
    /// `"gemini"`. Hydrated from `profile.settings["image_provider"]`.
    var imageProviderDraft: String = "openai"
    /// M27 — unit-system localization. `"us"` (default) or `"metric"`.
    /// Constrains AI-generated and AI-found recipes to use the right
    /// units. Hydrated from `profile.settings["unit_system"]`.
    var unitSystemDraft: String = "us"
    /// Current iOS notification authorization status (M18). Hydrated by
    /// `ensurePushBootstrap()` on `refreshAll()` and refreshed after the
    /// user toggles a push preference. Drives the "Open iOS Settings"
    /// hint in `SettingsView` when iOS has a denial on record.
    var pushAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Current household snapshot (M21). Loaded by `refreshHousehold()`
    /// during `refreshAll()`. Drives the Settings → Household section.
    var currentHousehold: HouseholdSnapshot?
    /// simmersmith-auc: leftover `household-*` zones discovery saw but did not pick, handed
    /// from `resolveHouseholdID()` to the post-launch cleanup pass. Plumbing, not UI — the
    /// whole point is that the user never hears about the empty ones.
    @ObservationIgnored var pendingLeftoverHouseholdIDs: [String] = []
    /// simmersmith-auc: leftover households that survived cleanup because they hold REAL
    /// records — a genuine fork, not build residue. Drives the Settings → Household notice.
    /// Empty in every normal case (and for a zone we merely couldn't read: a transient
    /// CloudKit failure must never masquerade as a fork).
    var forkedHouseholdIDs: [String] = []
    /// M22.5: Reminders bridge state must be @Observable stored
    /// properties — UserDefaults-backed computed properties don't
    /// trigger SwiftUI re-renders, which is why the Settings →
    /// Grocery section showed no feedback after Sync now in build 35.
    /// Hydrated in `loadCachedData()`; mutators persist to
    /// UserDefaults as a side effect for cross-launch persistence.
    var reminderListIdentifier: String?
    var lastReminderSyncAt: Date?
    var lastReminderSyncSummary: String?
    /// Token returned by `RemindersService.observeChanges`. Held so we
    /// can remove the observer on sign-out and avoid duplicate
    /// subscriptions when the user re-toggles Reminders sync.
    @ObservationIgnored
    var reminderObserver: NSObjectProtocol?
    /// Debounce handle for `EKEventStoreChanged` — iCloud emits a
    /// flurry of changes during sync, and we don't want to hit the
    /// server N times for one user-visible edit.
    @ObservationIgnored
    var reminderChangeDebounce: Task<Void, Never>?
    var aiDirectProviderDraft: String = ""
    var aiDirectAPIKeyDraft: String = ""
    var aiOpenAIModelDraft: String = ""
    var aiAnthropicModelDraft: String = ""
    /// SP-C "Open models" entry: the selected vendor (ollama|neuralwatt) and its model id.
    /// The single "Open models" provider row spans the visible vendors; the chosen model
    /// determines which vendor key + base URL is used (the picker sets both).
    var aiOpenModelsVendorDraft: String = ""
    var aiOpenModelsModelDraft: String = ""
    /// SP-C — CloudKit-path model dropdown state, keyed by provider
    /// ("openai"/"anthropic"). Populated by `refreshCKAIModels(for:)` from the
    /// provider's live `/v1/models` (curated) or the static fallback. The Settings
    /// "Model" Picker reads these; replaces the retired Fly `availableAIModelsByProvider`.
    var ckAIModelOptions: [String: [String]] = [:]
    var ckAIModelFetchError: [String: String] = [:]
    /// Keyed by provider so overlapping fetches (e.g. a fast provider flip) don't
    /// clear each other's spinner.
    var isFetchingAIModels: [String: Bool] = [:]
    /// SP-C — user overrides for the AI-assistant suggestion chips, keyed by pageType
    /// ("week"/"recipe_detail"/…). Empty for a screen = the built-in defaults. Hydrated
    /// from the private-plane `assistant_prompts` setting; edited in Settings → AI.
    var assistantPromptOverrides: [String: [String]] = [:]

    var profile: ProfileSnapshot?
    var currentWeek: WeekSnapshot?
    /// The non-current week the user has navigated to via the Week-tab
    /// picker (e.g. "next week"). Hoisted from WeekView's local @State
    /// in Build 104 so the assistant SSE handler can update it by
    /// week_id when AI tools mutate a week other than `currentWeek` —
    /// previously `case "week.updated"` overwrote `currentWeek` with
    /// whatever week the AI touched, corrupting the "this week" view
    /// and leaving the browsed week stale.
    var browsedWeek: WeekSnapshot?
    var recipes: [RecipeSummary] = []
    var recipeMetadata: RecipeMetadata?
    /// Memory-log entries keyed by recipeID. Refreshed lazily when
    /// the recipe-detail view appears; survives detail dismissal.
    var recipeMemories: [String: [RecipeMemory]] = [:]
    var aiCapabilities: AICapabilities?
    var exports: [ExportRun] = []
    var assistantThreads: [AssistantThreadSummary] = []
    var assistantThreadDetails: [String: AssistantThread] = [:]
    var ingredientPreferences: [IngredientPreference] = []
    /// M26 Phase 3 — per-household shorthand aliases. Loaded lazily
    /// when the Settings → AI → Custom terms screen opens.
    var householdAliases: [HouseholdTermAlias] = []
    /// M28 — pantry items (extends staples with typical-purchase
    /// quantity and recurring auto-add to weekly grocery). Loaded
    /// lazily when the Grocery → Pantry screen opens.
    var pantryItems: [PantryItem] = []
    var guests: [Guest] = []
    var eventSummaries: [EventSummary] = []
    var eventDetails: [String: Event] = [:]
    var checkedGroceryItemIDs: Set<String> = []
    var seasonalProduce: [InSeasonItem] = []
    var seasonalProduceFetchedAt: Date?
    /// One-shot search term that other tabs can plant when they want to
    /// hand off to the Recipes view. Consumed (cleared) by RecipesView in
    /// onChange/onAppear so it never re-applies on a back-navigation.
    var recipesPrefilledSearch: String?
    var availableAIModelsByProvider: [String: [AIModelOption]] = [:]
    var aiModelErrorByProvider: [String: String] = [:]

    // MARK: - SP-C slice 3: weeks import trigger state

    /// Tracks the one-shot Fly→CloudKit weeks+grocery import for the Settings trigger.
    /// `WeekImportState` enum is declared in `AppState+Recipes` (same extension).
    /// Needs to live here (main class body) to be tracked by `@Observable`.
    #if canImport(CloudKit)
    var weekImportState: WeekImportState = .idle
    #endif

    // MARK: - SP-C slice 4: events import trigger state

    /// Tracks the one-shot Fly→CloudKit events+guests+event-grocery import for the
    /// Settings trigger. `EventImportState` enum is declared in `AppState+Recipes`.
    /// Needs to live here (main class body) to be tracked by `@Observable`.
    #if canImport(CloudKit)
    var eventImportState: EventImportState = .idle
    #endif

    // MARK: - SP-C slice 5: pantry + profile import trigger state

    /// Tracks the one-shot Fly→CloudKit pantry+profile+prefs+aliases import for the
    /// Settings trigger. `PantryProfileImportState` enum is declared in `AppState+Recipes`.
    /// Needs to live here (main class body) to be tracked by `@Observable`.
    #if canImport(CloudKit)
    var pantryProfileImportState: PantryProfileImportState = .idle
    #endif

    // MARK: - SP-C factory reset: Start Fresh from Fly trigger state

    /// Tracks the destructive "Start Fresh from Fly" flow (wipe all CloudKit +
    /// re-import) for the Settings trigger. `StartFreshState` enum and the
    /// `StartFreshResult` summary are declared in `AppState+FactoryReset`.
    /// Needs to live here (main class body) to be tracked by `@Observable`.
    #if canImport(CloudKit)
    var startFreshState: StartFreshState = .idle
    #endif

    // MARK: - SP-C identity slice: CloudKit-only launch gate

    /// SP-C identity slice (spec §1.3): phases of the iCloud-native launch.
    /// RootView gates on this — shows a loading state while `.resolving`,
    /// `MainTabView` once `.ready`, and a friendly "Sign in to iCloud" prompt
    /// when `.iCloudUnavailable`. The Fly sign-in screen is no longer shown.
    enum HouseholdLaunchPhase: Equatable {
        /// CloudKit household resolution in progress (initial state).
        case resolving
        /// Household resolved — ready to show `MainTabView`.
        case ready
        /// iCloud account not signed in or CKAccountStatus is not `.available`.
        case iCloudUnavailable
    }

    /// Current phase of the iCloud-native launch gate.
    var householdLaunchPhase: HouseholdLaunchPhase = .resolving
    /// Orthogonal authority state: cached content can be visible before reconciliation.
    var householdAuthority: HouseholdAuthorityState = .none
    /// Independent per-user private-plane availability. Cached household content may render
    /// while this remains loading or unavailable.
    var personalDataReadiness: PersonalDataReadiness = .unavailable
    /// The intentionally deferred cached private-plane open. It is cancelled at teardown so a
    /// successor session cannot receive a stale repository reload.
    @ObservationIgnored var cachedPrivatePlaneTask: Task<Void, Never>?
    /// Resolved once at construction and injected through the session boot path.
    let cacheFirstLaunchEnabled: Bool
    let cacheFirstGateSource: CacheFirstGateSource
    static let cacheFirstLaunchOverrideKey = "sm.cacheFirstLaunchOverride"

    /// Single source of truth: this build is CloudKit-only. Features not yet
    /// migrated to CloudKit (Weeks / Grocery / Events / Profile / AI) render
    /// `ComingSoonView` at their tab entry points so no Fly call is made and
    /// no 401 banners appear. Recipes is the first (and currently only) fully
    /// cut-over feature; subsequent slices will flip their gating off.
    let isCloudKitOnly: Bool = AppState.cloudKitOnlyBuild

    var syncPhase: SyncPhase = .idle
    var lastErrorMessage: String?
    /// SP-C identity slice (review finding C): in CloudKit-only mode the `.week` tab
    /// renders `ComingSoonView`, so landing there opens the app on an hourglass. Default
    /// to the cut-over Recipes (Forge) tab instead. `defaultLandingTab` is the single
    /// source of truth for both the initial value and the post-clear reset.
    var selectedTab: MainTab = AppState.defaultLandingTab
    /// The tab the app should open to. `.week` now that Weeks + Grocery are cut over;
    /// the Recipes fallback is retained here only for historical reference.
    static var defaultLandingTab: MainTab { .week }
    /// Compile-time mirror of `isCloudKitOnly` so the static `defaultLandingTab` can read
    /// it without an instance. Keep in lockstep with `isCloudKitOnly`.
    private static let cloudKitOnlyBuild = true
    /// Build 68 — bumped whenever the user changes a per-tab top-bar
    /// primary action in Settings. Views that build toolbars read this
    /// (via @Observable) so the SwiftUI graph re-renders without
    /// needing each consumer to subscribe to UserDefaults directly.
    var topBarConfigRevision: UInt32 = 0
    var assistantSendingThreadIDs: Set<String> = []
    var assistantErrorByThreadID: [String: String] = [:]

    init(
        modelContainer: ModelContainer,
        settingsStore: ConnectionSettingsStore = .shared,
        apiClient: SimmerSmithAPIClient? = nil,
        cacheFirstLaunchEnabled: Bool? = nil,
        householdLifecycleDirectoryURL: URL? = nil,
        launchObservationRecorder: LaunchObservationRecorder? = nil
    ) {
        #if canImport(CloudKit)
        let lifecyclePaths = HouseholdLifecyclePaths.live(
            directoryOverride: householdLifecycleDirectoryURL)
        self.householdLifecyclePaths = lifecyclePaths
        self.householdLifecycleTransactionStore = HouseholdLifecycleTransactionStore(
            fileURL: lifecyclePaths.transactionURL)
        self.participantMarkerStore = ParticipantMarkerStore(
            fileURL: lifecyclePaths.participantMarkerURL)
        self.factoryResetImportMarkerStore = DurableLifecycleFlagStore(
            fileURL: lifecyclePaths.factoryResetImportMarkerURL)
        #endif
        self.settingsStore = settingsStore
        let connection = settingsStore.load()
        self.serverURLDraft = connection.serverURLString
        self.authTokenDraft = connection.authToken
        self.cacheStore = SimmerSmithCacheStore(modelContainer: modelContainer)
        self.apiClient = apiClient ?? SimmerSmithAPIClient(settingsStore: settingsStore)
        let gateResolution = Self.resolveCacheFirstLaunchPolicyDetails()
        self.cacheFirstLaunchEnabled = cacheFirstLaunchEnabled ?? gateResolution.enabled
        self.cacheFirstGateSource = cacheFirstLaunchEnabled == nil ? gateResolution.source : .testOverride
        self.launchObservationRecorder = launchObservationRecorder ?? LaunchObservationRecorder()
    }

    private static func resolveCacheFirstLaunchPolicy() -> Bool {
        resolveCacheFirstLaunchPolicyDetails().enabled
    }

    private static func resolveCacheFirstLaunchPolicyDetails() -> (enabled: Bool, source: CacheFirstGateSource) {
        #if DEBUG
        let receipt: CacheFirstReceiptEnvironment = .debug
        let isDebug = true
        #else
        let receipt: CacheFirstReceiptEnvironment
        switch Bundle.main.appStoreReceiptURL?.lastPathComponent {
        case "sandboxReceipt": receipt = .sandbox
        case "receipt": receipt = .appStore
        default: receipt = .unknown
        }
        let isDebug = false
        #endif
        let override = UserDefaults.standard.object(forKey: cacheFirstLaunchOverrideKey) as? Bool
        let enabled = CacheFirstLaunchPolicy.resolve(
            staticDefault: false,
            installOverride: override,
            receipt: receipt,
            isDebug: isDebug).enabled
        let source: CacheFirstGateSource
        if override != nil && (isDebug || receipt == .sandbox) {
            source = .installOverride
        } else {
            switch receipt {
            case .debug: source = .debug
            case .sandbox: source = .sandboxReceipt
            case .appStore: source = .appStoreReceipt
            case .unknown: source = .unknown
            }
        }
        return (enabled, source)
    }

    var hasSavedConnection: Bool {
        !ConnectionSettingsStore.normalizeServerURL(serverURLDraft).isEmpty
    }

    var syncStatusText: String {
        switch syncPhase {
        case .idle:
            return hasSavedConnection ? "Ready to sync." : "Configure a server to begin."
        case .loading:
            return "Refreshing from server…"
        case .synced(let date):
            return "Synced \(date.formatted(date: .abbreviated, time: .shortened))."
        case .offline:
            return "Showing cached content while offline."
        case .failed(let message):
            return message
        }
    }

    var recipeTemplateCount: Int {
        recipeMetadata?.templates.count ?? 0
    }

    /// SP-C AI-5: true iff a BYO key exists for the configured provider (KeychainKeyStore).
    /// Replaces the Fly aiCapabilities/hasSavedConnection check — the assistant runs
    /// on-device via AssistantEngine; no Fly connection is required.
    var assistantExecutionAvailable: Bool {
        #if canImport(CloudKit)
        // aiService being non-nil means the CloudKit session is live; aiDirectAPIKeyConfigured
        // checks the Keychain via providerAPIKeyConfigured → aiService.hasKey.
        if aiService != nil { return aiDirectAPIKeyConfigured }
        #endif
        return false
    }

    var aiDirectAPIKeyConfigured: Bool {
        if !aiDirectProviderDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // selectedAIKeychainID resolves "openmodels" to the chosen vendor's key
            // (zai/moonshot/minimax); nil → not yet resolvable → not configured.
            guard let kc = selectedAIKeychainID else { return false }
            return providerAPIKeyConfigured(providerID: kc)
        }
        return ["openai", "anthropic"].contains { providerAPIKeyConfigured(providerID: $0) }
    }

    var selectedDirectProviderModelDraft: String {
        get {
            switch aiDirectProviderDraft {
            case "openai":
                return aiOpenAIModelDraft
            case "anthropic":
                return aiAnthropicModelDraft
            default:
                return ""
            }
        }
        set {
            switch aiDirectProviderDraft {
            case "openai":
                aiOpenAIModelDraft = newValue
            case "anthropic":
                aiAnthropicModelDraft = newValue
            default:
                break
            }
        }
    }

    var selectedDirectProviderModels: [AIModelOption] {
        availableAIModelsByProvider[aiDirectProviderDraft] ?? []
    }

    var selectedDirectProviderModelError: String? {
        aiModelErrorByProvider[aiDirectProviderDraft]
    }

    /// SP-C AI-5: status text for the assistant setup state shown when
    /// `assistantExecutionAvailable == false`. References the BYO-key path.
    var assistantExecutionStatusText: String {
        #if canImport(CloudKit)
        if aiService != nil {
            // CloudKit session is live but no key is configured.
            return "Add your OpenAI or Anthropic API key in Settings → AI to use the Assistant."
        }
        return "Sign in with iCloud to use the Assistant."
        #else
        return "The Assistant requires iCloud."
        #endif
    }

    func loadCachedData() {
        #if canImport(CloudKit)
        guard !shouldSuppressLegacyCacheHydration else {
            detachLegacyCachedProjections()
            return
        }
        #endif
        profile = cacheStore.loadProfile()
        if let profile {
            syncAIDrafts(from: profile)
            syncRegionDraft(from: profile)
            syncImageProviderDraft(from: profile)
            syncUnitSystemDraft(from: profile)
            // Push drafts are derived from profile.settings — no extra sync needed;
            // ensurePushBootstrap() is called in refreshAll() after network hydration.
        }
        currentWeek = cacheStore.loadCurrentWeek()
        recipes = cacheStore.loadRecipes()
        recipeMetadata = cacheStore.loadRecipeMetadata()
        if let weekID = currentWeek?.weekId {
            exports = cacheStore.loadExports(for: weekID)
        }
        if let groceryItems = currentWeek?.groceryItems {
            // M22: server is the source of truth. Local cache load
            // (cold launch) trusts whatever was last persisted.
            checkedGroceryItemIDs = Set(
                groceryItems.filter(\.isChecked).map(\.groceryItemId)
            )
        } else {
            checkedGroceryItemIDs = []
        }
        // M22.5: hydrate the @Observable Reminders state so the
        // Settings sheet renders the right toggle / "Last synced"
        // values on first open.
        loadReminderState()
    }

    static let productionServerURL = "https://simmersmith.fly.dev"

    func signInWithApple(identityToken: String) async {
        lastErrorMessage = nil
        // Point at production server for the auth call
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        serverURLDraft = Self.productionServerURL

        do {
            let response = try await apiClient.signInWithApple(identityToken: identityToken)
            // Store the session JWT as the auth token
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: response.token)
            authTokenDraft = response.token
            await refreshAll()
        } catch {
            lastErrorMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func saveConnectionDetails() async {
        let normalizedURL = ConnectionSettingsStore.normalizeServerURL(serverURLDraft)
        settingsStore.save(serverURLString: normalizedURL, authToken: authTokenDraft)
        serverURLDraft = normalizedURL
        lastErrorMessage = nil
        await refreshAll()
    }

    func refreshAll() async {
        #if canImport(CloudKit)
        await replayPendingHouseholdLifecycleBeforeEntry()
        guard householdLifecycleAllowsEntry(), !factoryResetImportRequired else { return }
        let lifecycleProjectionEpoch = sessionBootEpoch
        if cacheFirstLaunchEnabled {
            await ensureHouseholdSession()
            return
        }
        #endif
        guard hasSavedConnection else {
            syncPhase = .idle
            return
        }

        syncPhase = .loading
        lastErrorMessage = nil

        do {
            let health = try await apiClient.fetchHealth()
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif
            aiCapabilities = health.aiCapabilities

            let fetchedProfile = try await apiClient.fetchProfile()
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif
            let serverWeek = try await apiClient.fetchCurrentWeek()
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif
            // Route through the same auto-advance helper used by
            // `refreshWeek` so cold launch shows today's week even
            // when the server's most-recently-started record is
            // ahead of or behind today's calendar week.
            let fetchedWeek = try await advanceCurrentWeekToTodayIfStaleOrNil(serverWeek)
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif

            profile = fetchedProfile
            syncAIDrafts(from: fetchedProfile)
            syncRegionDraft(from: fetchedProfile)
            syncImageProviderDraft(from: fetchedProfile)
            syncUnitSystemDraft(from: fetchedProfile)
            currentWeek = fetchedWeek
            // Best-effort: fire the APNs permission prompt once on first launch after sign-in.
            // A failure here must never crash bootstrap.
            await ensurePushBootstrap()
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif
            // Best-effort household snapshot for the Settings UI (M21).
            await refreshHousehold()
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            // SP-C Task 5 — now that the household ID is known (from the Fly snapshot),
            // construct + boot the CloudKit household session and its repositories. The
            // recipe data plane reads/writes CloudKit from here on; the CloudKit-aware
            // overloads in AppState+Recipes route through the repos once this is set.
            await ensureHouseholdSession()
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif
            checkedGroceryItemIDs = Set(
                (fetchedWeek?.groceryItems ?? [])
                    .filter(\.isChecked)
                    .map(\.groceryItemId)
            )

            try? cacheStore.saveProfile(fetchedProfile)

            if let fetchedWeek {
                try? cacheStore.saveCurrentWeek(fetchedWeek)
                let fetchedExports = try await apiClient.fetchWeekExports(weekID: fetchedWeek.weekId)
                #if canImport(CloudKit)
                guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                    detachLegacyCachedProjections()
                    return
                }
                #endif
                exports = fetchedExports
                try? cacheStore.saveExports(fetchedExports, for: fetchedWeek.weekId)
            } else {
                exports = []
            }

            #if canImport(CloudKit)
            // When CloudKit session is active, metadata comes from MetadataRepository
            // via the mirror set up in ensureHouseholdSession(). Fetching from Fly here
            // would clobber those mirrored values until the next storeRevision tick.
            if recipeRepository == nil {
                if let metadata = try? await apiClient.fetchRecipeMetadata() {
                    guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                        detachLegacyCachedProjections()
                        return
                    }
                    recipeMetadata = metadata
                    try? cacheStore.saveRecipeMetadata(metadata)
                }
            }
            #else
            if let metadata = try? await apiClient.fetchRecipeMetadata() {
                recipeMetadata = metadata
                try? cacheStore.saveRecipeMetadata(metadata)
            }
            #endif

            // SP-C AI-5: assistant threads now live in the private plane (AssistantRepository).
            // refreshAssistantThreads() is called after ensureHouseholdSession() wires the
            // repository; the Fly fetchAssistantThreads() call is retired.
            await refreshAssistantThreads()
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif
            // Ingredient preferences are private-plane only in the CloudKit build.
            #if canImport(CloudKit)
            if let prefRepo = preferenceRepository {
                prefRepo.reload()
                ingredientPreferences = prefRepo.preferences
            } else {
                ingredientPreferences = []
            }
            #else
            ingredientPreferences = []
            #endif
            await refreshAIModels(for: aiDirectProviderDraft)
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif

            syncPhase = .synced(.now)
        } catch {
            #if canImport(CloudKit)
            guard householdProjectionEpochIsCurrent(lifecycleProjectionEpoch) else {
                detachLegacyCachedProjections()
                return
            }
            #endif
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    /// True if the error is a benign cancellation (Task or URLSession)
    /// that happens during normal view lifecycle — sheet dismissal,
    /// rapid navigation, app backgrounding. Surfacing these as red
    /// banners ("cancelled") is noise; callers should treat them as
    /// "stop without complaint". Build 104.
    func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    func clearLocalCache() {
        // Cancel any in-flight refresh started by a previous clearLocalCache
        // call so we do not race a fresh sync against the reset we are about
        // to perform.
        postClearRefreshTask?.cancel()
        postClearRefreshTask = nil
        try? cacheStore.clearAll()
        profile = nil
        currentWeek = nil
        recipes = []
        recipeMetadata = nil
        exports = []
        assistantThreads = []
        assistantThreadDetails = [:]
        checkedGroceryItemIDs = []
        // User/household-scoped collections that must NOT survive a cache
        // clear or sign-out (otherwise the previous user's data bleeds into
        // the next account on the same device). currentHousehold is also
        // cleared via resetConnection()->clearHouseholdContext(), but the
        // standalone "Clear Local Cache" button bypasses that path.
        browsedWeek = nil
        recipeMemories = [:]
        ingredientPreferences = []
        householdAliases = []
        pantryItems = []
        guests = []
        eventSummaries = []
        eventDetails = [:]
        seasonalProduce = []
        seasonalProduceFetchedAt = nil
        currentHousehold = nil
        syncPhase = .idle
        lastErrorMessage = nil
        // Review finding C: reset to the cut-over landing tab, not `.week` (which renders
        // ComingSoonView in CloudKit-only mode).
        selectedTab = AppState.defaultLandingTab
        assistantSendingThreadIDs = []
        assistantErrorByThreadID = [:]
        aiProviderModeDraft = "auto"
        aiDirectProviderDraft = ""
        aiDirectAPIKeyDraft = ""
        aiOpenAIModelDraft = ""
        aiAnthropicModelDraft = ""
        availableAIModelsByProvider = [:]
        aiModelErrorByProvider = [:]
        if hasSavedConnection {
            syncPhase = .loading
            postClearRefreshTask = Task { [weak self] in
                await self?.refreshAll()
            }
        }
    }

    func resetConnection() {
        // Cancel any in-flight refresh so it does not try to use the
        // connection we are about to clear.
        postClearRefreshTask?.cancel()
        postClearRefreshTask = nil
        // F29: best-effort unregister this device for the signing-out user
        // and drop the push dedup key BEFORE clearing the connection — the
        // DELETE needs the server URL + bearer token that settingsStore.clear()
        // is about to wipe. Without this, the next user on a shared device
        // keeps the old device row and never re-registers (same APNs token).
        PushService.shared.reset(apiClient: apiClient)
        settingsStore.clear()
        serverURLDraft = ""
        authTokenDraft = ""
        clearHouseholdContext()
        // M22: drop the per-device Reminders mapping. The next user
        // who signs in on this device gets a clean mapping for their
        // chosen Reminders list.
        clearReminderMappings()
        clearLocalCache()
    }

    var hasCachedContent: Bool {
        profile != nil || currentWeek != nil || !recipes.isEmpty || !exports.isEmpty
    }
}

/// Receipt environment used to resolve the test-only cache-first launch policy.
enum CacheFirstReceiptEnvironment: Equatable {
    case debug
    case sandbox
    case appStore
    case unknown
}

/// Pure launch policy. The shipping default is intentionally off; only DEBUG or a sandbox
/// receipt may honor the install-local override.
struct CacheFirstLaunchPolicy: Equatable {
    let enabled: Bool

    static func resolve(
        staticDefault: Bool,
        installOverride: Bool?,
        receipt: CacheFirstReceiptEnvironment,
        isDebug: Bool
    ) -> CacheFirstLaunchPolicy {
        guard isDebug || receipt == .sandbox else {
            return CacheFirstLaunchPolicy(enabled: staticDefault && receipt == .appStore)
        }
        return CacheFirstLaunchPolicy(enabled: installOverride ?? staticDefault)
    }
}

/// Household content availability is intentionally separate from sync authority.
enum HouseholdAuthorityState: Equatable {
    case none
    case reconciling(cachedAt: Date)
    case current(Date)
    case offlineCached(cachedAt: Date)
    case pending(count: Int)
    case degraded(message: String)
    case intervention(message: String)
}

/// Foreground must not treat a visible cached session as terminal when its previous
/// reconciliation was offline or degraded. The retry itself still goes through AppState's
/// serialized boot queue so it cannot overlap an adoption or another boot operation.
enum CachedForegroundRetryPolicy {
    static func shouldRetry(
        hasCachedSession: Bool,
        authority: HouseholdAuthorityState,
        hasPendingDeferredSystemWork: Bool = false
    ) -> Bool {
        guard hasCachedSession else { return false }
        if hasPendingDeferredSystemWork { return true }
        switch authority {
        case .offlineCached, .degraded:
            return true
        default:
            return false
        }
    }
}

enum DirectHouseholdBootstrapPolicy {
    static func shouldContinueAfterInitialStart(
        isCachedBootstrap: Bool,
        hasCurrentAuthority: Bool
    ) -> Bool {
        isCachedBootstrap || hasCurrentAuthority
    }
}

enum CachedHouseholdRetryPlan: Equatable {
    case reconcile
    case resumeDeferredSystemWork

    static func next(
        hasCurrentAuthority: Bool,
        hasPendingDeferredSystemWork: Bool
    ) -> CachedHouseholdRetryPlan {
        hasCurrentAuthority && hasPendingDeferredSystemWork
            ? .resumeDeferredSystemWork
            : .reconcile
    }
}

/// Direct/recovery publication is explicit: a successful direct boot becomes current first,
/// then reports the exact durable pending count, then terminally surfaces any intervention.
/// An offline direct boot remains content-compatible but never claims current authority.
enum DirectHouseholdAuthorityPlan {
    static func events(
        isSynchronized: Bool,
        pendingCount: Int,
        interventionCount: Int,
        now: Date
    ) -> [HouseholdAuthorityEvent] {
        guard isSynchronized else {
            return [.degraded("Household sync is offline.")]
        }
        var events: [HouseholdAuthorityEvent] = [
            .directReady(now),
            .pending(count: pendingCount),
        ]
        if interventionCount > 0 {
            let noun = interventionCount == 1 ? "change" : "changes"
            let verb = interventionCount == 1 ? "needs" : "need"
            events.append(.intervention("\(interventionCount) durable \(noun) \(verb) attention."))
        }
        return events
    }
}

/// P2e's complete fail-closed inventory for local-absence and system operations. P2f replaces
/// this blanket cached-session denial with exact authority/lifecycle checks.
enum CachedHouseholdSystemOperation: CaseIterable {
    case migration
    case currentWeekCreation
    case repair
    case leftoverCleanup
    case factoryReset
    case ownerShareCreation
    case backupRestore
}

/// App-level authoritative-operation result. User-facing callers either return or throw the
/// retryable denial; internal boot helpers use the same value to keep cached receipts from
/// suppressing authoritative work.
enum CachedHouseholdSystemOperationResult: Error, Equatable, LocalizedError {
    case allowed
    case retryableNotAuthoritative

    var errorDescription: String? {
        switch self {
        case .allowed:
            return nil
        case .retryableNotAuthoritative:
            return "Finish household reconciliation before trying that again."
        }
    }
}

enum CachedHouseholdSystemOperationPolicy {
    static func result(
        _ operation: CachedHouseholdSystemOperation,
        isAuthoritative: Bool
    ) -> CachedHouseholdSystemOperationResult {
        isAuthoritative ? .allowed : .retryableNotAuthoritative
    }

    static func allows(
        _ operation: CachedHouseholdSystemOperation,
        isAuthoritative: Bool
    ) -> Bool {
        result(operation, isAuthoritative: isAuthoritative) == .allowed
    }

    /// Compatibility seam for P2e-focused tests. Production call sites must pass the current
    /// session capability so cached sessions may run the deferred tail exactly once after fetch.
    static func allows(
        _ operation: CachedHouseholdSystemOperation,
        isCachedBootstrap: Bool
    ) -> Bool {
        !isCachedBootstrap
    }
}

enum PersonalDataReadiness: Equatable {
    case unavailable
    case loading
    case ready
}

enum HouseholdAuthorityEvent: Equatable {
    case cachedReady(Date)
    case directReady(Date)
    case reconciliationSucceeded(Date)
    case reconciliationFailed(String)
    case retry(Date)
    case pending(count: Int)
    case degraded(String)
    case intervention(String)
    case resolveIntervention(Date)
    case teardown
}

/// Pure, epoch-aware authority reducer. Callers pass the captured epoch and exact session
/// identity after every await; stale events are no-ops and cannot resurrect a torn-down session.
enum HouseholdAuthorityReducer {
    static func reduce(
        _ state: HouseholdAuthorityState,
        event: HouseholdAuthorityEvent,
        epoch: Int,
        currentEpoch: Int,
        sessionMatches: Bool,
        now: Date = Date()
    ) -> HouseholdAuthorityState {
        guard epoch == currentEpoch, sessionMatches else { return state }
        if case .teardown = event { return .none }
        if case .intervention(let message) = event { return .intervention(message: message) }
        if case .intervention = state {
            guard case .resolveIntervention(let date) = event else { return state }
            return .current(date)
        }
        switch event {
        case .cachedReady(let date): return .reconciling(cachedAt: date)
        case .directReady(let date): return .current(date)
        case .reconciliationSucceeded(let date):
            if case .pending = state { return state }
            return .current(date)
        case .reconciliationFailed:
            if case .reconciling(let date) = state { return .offlineCached(cachedAt: date) }
            return .degraded(message: "Household reconciliation failed.")
        case .retry(let date): return .reconciling(cachedAt: date)
        case .pending(let count):
            if count > 0 { return .pending(count: count) }
            if case .pending = state { return .current(now) }
            return state
        case .degraded(let message): return .degraded(message: message)
        case .intervention, .resolveIntervention, .teardown: return state
        }
    }

}
