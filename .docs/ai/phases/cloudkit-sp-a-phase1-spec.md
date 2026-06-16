# SP-A Phase 1 — Per-user PRIVATE plane (spec + report)

Status: **BUILT + VERIFIED LIVE 2026-06-15** (single-device). Two-device convergence is
the one manual residual.

## Decision: SwiftData-over-CloudKit (= NSPersistentCloudKitContainer)

Phase 0.5 proved an `NSPersistentCloudKitContainer` store and a custom CKSyncEngine-style
stack coexist in one container. The app **already** uses SwiftData for its local cache
(`SimmerSmithKit/Persistence/{CacheModels,ModelContainerSetup}.swift`,
`cloudKitDatabase: .none`). SwiftData's `cloudKitDatabase: .private(...)` **is** NSPCKC
underneath, so Phase 1 rides SwiftData rather than bolting on a raw Core Data model —
matches the existing idiom, far less boilerplate, same engine the verdict blessed.

The PRIVATE plane is a **separate `ModelConfiguration`/store** ("SimmerSmithPrivate") from
the local-only cache store, in the same container build. Local cache stays `.none`; the
private plane is `.private("iCloud.app.simmersmith.cloud")`.

### CD_ schema vs the hand-authored types (important, non-obvious)

NSPCKC generates its **own** CD_-prefixed CloudKit record types (`CD_PrivateProfileSetting`,
…) from the `@Model` classes. It does **not** use the hand-authored `ProfileSetting` /
`DietaryGoal` / … record types deployed to dev via cktool in Phase 0. Those hand-authored
types are not wasted — they serve the **SHARED household zone**'s custom CKSyncEngine stack
(Phase 2+), whose recordName policy + field-merge resolver NSPCKC can't express. So the dev
schema will carry both `ProfileSetting` (unused by the PRIVATE plane) and, after first run,
`CD_PrivateProfileSetting`. That's fine (additive). The hand-authored PRIVATE-plane types
stay as the migration target shape: field names on the `@Model`s mirror the CKDSL so the
Phase 7 import maps 1:1.

## Files

- `SimmerSmithKit/Sources/SimmerSmithKit/Persistence/PrivatePlaneModels.swift` — 7
  CloudKit-safe `@Model` types (Private-prefixed to avoid colliding with the same-named
  Codable wire structs): `PrivateProfileSetting`, `PrivateDietaryGoal`,
  `PrivatePreferenceSignal`, `PrivateIngredientPreference`, `PrivateAssistantThread`,
  `PrivateAssistantMessage`, `PrivateMigrationReceipt`.
- `…/Persistence/PrivatePlaneContainer.swift` — `makeSimmerSmithPrivatePlaneContainer(inMemory:)`
  + the model-type list + container id constant.
- `…/Persistence/PrivatePlaneStore.swift` — upsert/invariant enforcement.
- `…/Tests/SimmerSmithKitTests/PrivatePlaneStoreTests.swift` — 7 headless invariant tests
  (in-memory, CloudKit-off).
- `SimmerSmith/SimmerSmith/Features/Settings/CloudKitDebugView.swift` — adds the "Phase 1 —
  private plane CRUD" check (`runPrivatePlaneCheck()`).

## CloudKit-sync rules the `@Model`s obey

- **No `@Attribute(.unique)`** — CloudKit can't enforce uniqueness. Identity is a stable
  `recordKey` string; uniqueness held by fetch-before-insert upserts in `PrivatePlaneStore`.
- Every non-optional stored property has a **default value**.
- Relationships are **optional** with explicit inverse + delete rule
  (`PrivateAssistantThread.messages` ←→ `PrivateAssistantMessage.thread`, cascade).

## Identity policy (per type)

| Type | recordKey | Invariant |
|---|---|---|
| ProfileSetting | the setting key | singleton per key |
| DietaryGoal | `"dietary_goal"` | global singleton |
| PreferenceSignal | `"<signalType>:<normalizedName>"` | deterministic, dedupes |
| IngredientPreference | the app's `preferenceId` | id-keyed upsert |
| AssistantThread | the app's `threadId` | id-keyed |
| AssistantMessage | the app's `messageId` | id-keyed; ordered by `createdAt` |
| MigrationReceipt | the migration scope | claim-once sentinel |

## Verify

- **Headless**: `cd SimmerSmithKit && swift test` → all green (7 new invariant tests).
- **On-device (DONE 2026-06-15)**: signed build on the iPad sim signed into Taylor's
  iCloud → DEBUG CloudKit-checks panel → "Phase 1 — private plane CRUD" returned all ✅,
  incl. **"CloudKit-backed private store loaded ✅"** (NSPCKC inits against the real
  account + entitlement + container and generates the CD_ schema).
- **Residual (manual, deferred)**: profile/prefs/transcript create-edit-delete **across two
  devices** on one iCloud account — needs a second signed-in device; same manual gate as
  the CKShare cross-account test. Single-device persistence + every invariant are proven.

## Not in Phase 1 (later phases)

The live app still reads/writes per-user data via the Fly backend. Phase 1 builds the
CloudKit plane **alongside** (verified through the debug panel, like Phases 0/0.5); wiring
the live UI onto it and the one-time import are Phase 7 (migration import + cutover).
