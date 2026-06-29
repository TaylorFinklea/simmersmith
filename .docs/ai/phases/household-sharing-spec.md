# Household Sharing v1 (two-account CKShare) — Spec

**Status:** approved design, pre-plan. Authored 2026-06-28 (Opus) from a deep-research workflow: CKShare-accept→shared-engine-fetch seam research + share-metadata-delivery research + a precise code re-map → synthesis → adversarial critique. Critique verdict `needs-revision` with 4 corrections — all folded in (see **§15 Adversarial review applied**).

**Goal:** Let an owner share their single private-DB household zone with **exactly one** partner over a **zone-wide CKShare** (readWrite); the partner **adopts** the owner's household (her solo data stays parked — **no merge**) and both fully edit, live.

**Locked scope (user-approved):** owner + exactly one partner · **both fully edit** (readWrite) · **adopt, not merge** · **all settings stay per-user** · architected so N-members is a clean later add.

---

## 1. Architecture

CloudKit's model: one `CKSyncEngine` per **database scope**. The owner's household lives in their **private** DB; a participant reaches it via the **shared** DB. So a participant device runs a **second** engine bound to `sharedCloudDatabase` + the owner's zone.

Realized as a thin **`Role`** on the existing `HouseholdSession` — `HouseholdSyncEngine` is already scope-agnostic (takes `database` + `zoneID`), so the engine barely changes.

```swift
enum HouseholdSessionRole: Sendable, Equatable {
    case owner
    case participant(sharedZoneID: CKRecordZone.ID)
    var isOwner: Bool { if case .owner = self { return true }; return false }
}
```

- `HouseholdSession.init(householdID:role: = .owner)` — **the default preserves every existing owner call site verbatim** (`HouseholdSession(householdID:)` at `AppState+Recipes.swift:60` compiles unchanged).
- Role-dependent inside init: database = `role.isOwner ? privateCloudDatabase : sharedCloudDatabase` (today's hardcoded private at `HouseholdSession.swift:76`); zoneID = passed `sharedZoneID` for participant, else the deterministic `HouseholdZoneProvisioner.zoneName(householdID:)` (lines 82-83).
- **Per-scope sync-state isolation (hard requirement):** the engine-state token file (lines 89-96) must differ by scope — `engine-state.json` (owner) vs `engine-state-shared.json` (participant) — so the two engines never share a serialization blob.
- Engine gains one init arg `ownsZone: Bool = true`; participant passes `false` (see §2).
- The public-catalog reader (line 114) and the NSPCKC private plane (settings/AI keys, lines 42/130) are **unchanged for both roles** — settings stay per-user.
- v1: at most ONE active `HouseholdSession` per device (a participant adopts; it does not also run an owner engine for the same data). N-member-later: the Role already carries a per-participant zone ID; nothing assumes a single participant.

## 2. HouseholdSyncEngine changes (`ownsZone` + share filter + revocation)

`HouseholdSyncEngine.swift` (SimmerSmithCloudKit/Sources/HouseholdSync/):
- Add `ownsZone: Bool = true` init param. When **false** (participant): do NOT enqueue `.saveZone` on first save (lines 74-78), and do NOT recreate the zone on `.zoneNotFound`/`.userDeletedZone` (lines 249-252) — the participant does not own the zone.
- **Share-record filter:** a `CKShare` surfaces back through fetched changes as a record. Skip records whose `recordType == "cloudkit.share"` or `recordID.recordName == CKRecordNameZoneWideShare` in `handleEvent`'s fetched + sent loops (lines 154-201) and in `HouseholdLocalStore` ingestion, so the share is never mis-ingested as household data. **(Runs on the owner engine too — must be inert/benign; verify it never drops a legitimately-typed household record.)**
- **Zone revocation:** add a `.fetchedDatabaseChanges` zone-**deletion** handler (the case is a no-op today, lines 207-211) → purge the local mirror + drop back to owner/solo. **CRITICAL (critique #3):** this branch runs on the OWNER engine too — it must be **gated so an owner `userDeletedZone` never spuriously wipes the owner mirror.** Owner-safety is an explicit acceptance criterion.

## 3. Owner share-create — ZONE-WIDE, new methods (don't edit debug helpers)

The household lives in the deterministic private zone `household-<id>`. Create a **zone-wide** share:
- `CKShare(recordZoneID: zone.zoneID)` — NOT `CKShare(rootRecord:)`. (Hierarchical shares only the profile record → participant sees an empty household.)
- **Named-participant model** (exactly one partner): leave `publicPermission = .none` and present **`UICloudSharingController`** so the owner picks the partner and CloudKit mints the link. Set `share[CKShare.SystemFieldKey.title]`.
- Save via `privateCloudDatabase.modifyRecords(saving:[share], deleting:[])` — a zone-wide share has **no root record** to co-save (drop `profile` from the saved set). Verify zone-wide via `share.recordID.recordName == CKRecordNameZoneWideShare`.
- **Do NOT edit `HouseholdShareFlow.createAndPublishShare` / `acceptAndRead` in place (critique #2)** — `CloudKitDebugView.swift:881/897/898` still depends on their hierarchical shape (`metadata.hierarchicalRootRecordID`). Add **NEW** zone-wide create + accept methods; leave the debug helpers intact.
- Surface from a new owner Settings row (replacing "Invite a member").
- **MUST-VERIFY-ON-DEVICE:** the zone-wide share + `UICloudSharingController` round-trips, and the owner's existing private engine does not loop/error on the share record (no Apple CKSyncEngine+sharing sample exists — highest-risk owner-side item).

## 4. Accept entry point (scene delegate, iOS 26)

The deprecated `application(_:userDidAcceptCloudKitShareWith:)` does **not** fire for SwiftUI `WindowGroup` apps. Use the scene path:
1. **`Info.plist`: add `CKSharingSupported = YES`** — without it the system never hands over metadata.
2. From the existing `@UIApplicationDelegateAdaptor` (`SimmerSmithAppDelegate`), implement `application(_:configurationForConnecting:options:)` returning a `UISceneConfiguration` with `delegateClass = ShareSceneDelegate`.
3. **New `ShareSceneDelegate: NSObject, UIWindowSceneDelegate`** — exactly two methods: `windowScene(_:userDidAcceptCloudKitShareWith:)` (warm/running tap) and `scene(_:willConnectTo:options:)` *solely* to read `connectionOptions.cloudKitShareMetadata` (cold-launch). **Do NOT create/assign `self.window`** (WindowGroup owns it).
4. Guard `metadata.containerIdentifier == "iCloud.app.simmersmith.cloud"`. Thread metadata to AppState on the main actor. Cold-launch metadata can arrive **before** AppState exists → stash in a `@MainActor` `PendingShareInbox`; `SimmerSmithApp`'s `.task` drains it after `appDelegate.appState = appState` is set. Then call `AppState.acceptHouseholdShare(metadata:)`.
- Cold-launch metadata is **one-shot** — persist it until accept succeeds.

## 5. Participant boot + fetch — THE make-or-break seam

`AppState.acceptHouseholdShare(metadata:)` (new, parallel to `ensureHouseholdSession` at `AppState+Recipes.swift:23`). Research confidence **MEDIUM-HIGH**; device-gated steps marked **MUST-VERIFY-ON-DEVICE**:

1. Guard not-already-owner: skip if `metadata.participantRole == .owner` (owner tapping own link is benign — no error).
2. **Accept:** `CKAcceptSharesOperation([metadata])` on the container, await completion (reuse the `acceptShare` pattern at `HouseholdShareFlow.swift:127-138`). **Apple-documented race:** `accept()` can return **before** the server finishes creating the zone in the shared DB → the next fetch can race empty.
3. **Resolve the shared zone ID** from `metadata.share?.recordID.zoneID` (for a zone-wide share `metadata.hierarchicalRootRecordID` is **nil** — the old `acceptAndRead` read path cannot be reused). **MUST-VERIFY**; fallback: enumerate `sharedCloudDatabase.allRecordZones()` after accept.
4. Construct `HouseholdSession(householdID:…, role: .participant(sharedZoneID:))`; `await session.start()`. **Note (critique #4):** `start()` ALREADY calls `engine.fetchChanges()` (line 155) — so the post-accept fetch below is a **retry layered on that**, not the only fetch. `start()`'s raced `.offline` (line 160) must **NOT** be treated as a terminal accept failure.
5. **The fetch (MUST-VERIFY):** after start, call `try await session.engine.fetchChanges()` once more **from this Task** (never inside `handleEvent` — breaks serial ordering). Default `.all` scope (granted zone may not be known yet; the database-changes pass reveals it, then the engine auto-drives the record-zone pass → records land via the existing `.fetchedRecordZoneChanges` handler, lines 154-188). Rationale (MUST-VERIFY): the accepting device usually gets **no push for its own acceptance**, so `automaticallySync` alone may leave the zone unfetched. **Retry once after ~1.5s backoff** (mirror `discoverWithZeroZoneRetry`, line 271) if empty — never treat an empty first fetch as "no data."
6. Steady state: after the first fetch establishes the zone+subscription, `automaticallySync` covers bidirectional edits (MUST-VERIFY both directions).
7. Wire repositories EXACTLY as `ensureHouseholdSession` does (lines 71-157); set `householdLaunchPhase = .ready`. Persist a durable **participant marker** `{ sharedZoneID, ownerStamp }` (UserDefaults/file) — load-bearing for adopt-across-launches (§6).

## 6. Adopt semantics + the cold-launch ordering invariant

**Adopt = pointer-swap to the owner's zone, ZERO copy/merge.** Her private `household-<id>` zone stays **parked** in her private DB (recoverable); her per-user NSPCKC settings are unchanged. No merge code is written anywhere.

**Across launches** — `ensureHouseholdSession` (`AppState+Recipes.swift:23`) today discovers her private zone and boots as **owner**. After adopt she must re-boot as **participant**:
- **Early branch (critique #1 — the one real correctness hole):** at the TOP of `ensureHouseholdSession`, BEFORE private-zone discovery (before line 51 `resolveHouseholdID`), check **both** (a) a **pending** share in `PendingShareInbox` (first cold-accept — marker not yet written) **and** (b) the durable **participant marker** (re-launch). If either is present → take the participant-boot path and **return** before owner discovery. Only fall through to owner discovery when neither exists.
- **Invariant + acceptance test:** a zero-zone **cold-accept must never mint an owner household.** `SimmerSmithApp.swift:50` calls `ensureHouseholdSession()` unconditionally in `.task`; the PendingShareInbox check must run before owner discovery (or the drain must provably run before line 50). This "accept-before-mint" ordering is owned by one task (§12 Task 6), not split.
- **Warm-accept swap (critique #4):** if `householdSession != nil` (already booted as owner), `acceptHouseholdShare` must **replace** the owner session + rewire repos, **stop the old owner engine**, and **NOT** clear `engine-state.json` (the parked solo zone must survive a future un-adopt).
- `ownerStamp` lets the participant detect an owner-account swap (surface an error rather than silently mixing).
- **Re-entrancy:** `acceptHouseholdShare` and `ensureHouseholdSession` both assign `householdSession`. The accept path must share the `householdSessionSetupTask` dedup (or an equivalent single guard) so a concurrent foreground `ensureHouseholdSession` (scenePhase `.active` retry, line 73) can't race the accept.

## 7. Retire the Fly invite/join + hard-gate the merge

- `SettingsView` HouseholdSection (`SettingsView.swift:1332-1454`): remove the Fly "Invite a member" (1370-1406) and "Join a household" (1408-1414) buttons. Replace with an **owner row** (presents the zone-wide CKShare via `UICloudSharingController`) and a **participant status row** ("Shared by <owner>") when the marker is set.
- `InvitationSheet.swift`: retire `InvitationSheet` + `JoinHouseholdSheet` (the code-entry merge UI) — the CKShare link is delivered by the native share sheet + system accept.
- **HARD-GATE the merge:** `AppState.joinHousehold(code:)` (`AppState+Household.swift:67-82`) does a Fly server-side household merge — exactly what adopt forbids. Make it a no-op returning false (remove its caller at `SettingsView.swift:1441`), so adopt-not-merge cannot be violated.
- Keep Fly **auth/identity** intact (`signInWithApple`, the one-shot Fly→CloudKit imports, `refreshHousehold`, `renameHousehold`). Only the invite/join/merge surfaces go.

## 8. Error handling

- Any throw in `acceptHouseholdShare` → `householdLaunchPhase = .offline` (or `.iCloudUnavailable` for `CKError.notAuthenticated`/`.accountTemporarilyUnavailable` via existing `isICloudAuthError`, line 298) + `lastErrorMessage`; leave the marker UNSET so a foreground retry (scenePhase `.active`, line 73) re-attempts (persist the one-shot metadata until accept succeeds).
- Post-accept fetch race → retry once after backoff before concluding empty.
- Accept-as-owner → silently ignore.
- Zone revocation → purge mirror, clear marker, fall back to owner discovery next boot; never push the deletion back as a user delete.
- Writes use the same `engine.save` path; `.serverRecordChanged` field-merge (lines 228-248) is unchanged.
- Participant `.zoneNotFound` (ownsZone=false) must NOT recreate the zone — surface transient, rely on refetch.

## 9. Owner-path regression guards (softened per critique #3)

The owner flow is **unchanged except two device-gated additions** (NOT "provably unchanged"):
- **Unchanged by construction:** `role` defaults `.owner` → all call sites compile/behave identically; owner database=private, deterministic zone name, zone provisioning still runs (`if role.isOwner { ensureHouseholdZone }` only ADDS a participant skip), engine `ownsZone:true` preserves `.saveZone` + `.zoneNotFound` recreation; owner keeps `engine-state.json`; **no repository write-gating is added** (the investigation's `ensureCanWrite` is rejected — it contradicts "both edit").
- **New owner-engine surface (device-gated, must be verified inert/benign):** (a) the side-channel zone-wide share-create, (b) the share-record loopback **filter**, (c) the `.fetchedDatabaseChanges` deletion split (must not wipe the owner mirror on `userDeletedZone`). Verify on device; do not assert.
- **Regression test:** the two-device gate runs an **owner-only sync round-trip first** to confirm parity before any sharing.

## 10. Test plan

**Headless units (Swift Testing, no iCloud):**
(a) Role: `.owner` default → private DB + deterministic zone name; `.participant` → shared DB + passed zone ID + `engine-state-shared.json`.
(b) Engine `ownsZone`: `false` never enqueues `.saveZone`/zone-recreate; `true` (default) unchanged (owner guard).
(c) Share-record filter drops `cloudkit.share`/`CKRecordNameZoneWideShare` before `HouseholdLocalStore`; never drops a real household record.
(d) Owner share-create builds `CKShare(recordZoneID:)` (no rootRecord co-save).
(e) Adopt persistence: with a pending share OR a marker, `ensureHouseholdSession` takes the participant branch and does NOT run private-zone discovery; **zero-zone cold-accept never mints** an owner household; absent both, owner discovery unchanged.
(f) Fly `joinHousehold(code:)` is a no-op/unreachable.
(g) Owner `.fetchedDatabaseChanges` `userDeletedZone` does NOT purge the owner mirror.

**Two-REAL-DEVICE human gate (cannot be simulated — two different iCloud accounts, A=owner, B=participant; each `[?] awaiting human verify`):**
1. Owner-only round-trip parity first (regression).
2. A creates the zone-wide share via `UICloudSharingController`, sends link.
3. B **warm** accept → records appear without relaunch (proves the post-accept fetch).
4. B **cold** accept (force-quit → tap link → `connectionOptions.cloudKitShareMetadata`) → records still fetch; **no orphan owner zone minted**.
5. Accept→immediate-fetch race — note first-fetch vs retry; tune backoff.
6. Bidirectional readWrite — edit on B appears on A and vice-versa via `automaticallySync`.
7. B's solo private household stays parked/untouched; B's per-user settings unchanged.
8. Revocation — A removes B / deletes share → B purges local + clears marker; A's data intact.
9. Restart B → resumes from saved shared state, re-boots as participant (marker), no full refetch.

## 11. Ops preconditions (HUMAN — not code tasks)

- **Deploy the CloudKit schema to PRODUCTION** for `iCloud.app.simmersmith.cloud` (Dev→Prod in the Console) for all household record types + the `cloudkit.share` system type — TestFlight targets Production; a participant fetch returns empty if prod schema lags. (This is the same pending deploy noted in earlier handoffs.)
- **Flip `aps-environment` to `production`** for the TestFlight build (`SimmerSmith.entitlements` currently ships `development`) — steady-state shared sync rides the push channel.
- Confirm the iCloud entitlement (`com.apple.developer.icloud-services = [CloudKit]`) + the new `CKSharingSupported` Info.plist key are in the signed build. (There is no separate "CloudKit Sharing" entitlement.)
- Fix the public-catalog write-permission (set `_icloud` read-only on BaseIngredient/IngredientVariation/RecipeTemplate, redeploy) — already tracked; a clean participant first-run nutrition path depends on a published Production catalog.
- **Two physical iOS devices on two different iCloud accounts** for the gate — simulators can't exercise CKShare accept / shared-DB push.

## 12. Task breakdown (ordered, subagent-sized; critique fixes folded in)

- **T1 — Role enum + HouseholdSession parameterization.** `HouseholdSessionRole` + `let role`; `init(householdID:role: = .owner)` selects DB/zoneID/scope-suffixed state file; gate zone provisioning to owner. *Files:* `HouseholdSession.swift` (enum; props ~27; init 73-115; provisioning 137-139; stateURL 89-96). *Accept:* owner call sites compile unchanged; unit (a) passes; owner provisioning branch byte-identical.
- **T2 — Engine `ownsZone` + share-record filter + revocation.** *Files:* `HouseholdSyncEngine.swift` (init 47-66; save 72-79; handleEvent 154-201; fetchedDatabaseChanges 207-211; failure 249-252). *Accept:* units (b)(c)(g); the deletion-purge + filter are proven **owner-safe** (owner `userDeletedZone` does not wipe the owner mirror).
- **T3 — Owner zone-wide share + share sheet.** **NEW** zone-wide create/accept methods (leave `HouseholdShareFlow` hierarchical helpers + `CloudKitDebugView` intact); owner Settings row presents `UICloudSharingController`. *Accept:* unit (d); debug round-trip still builds.
- **T4 — Scene-delegate accept + Info.plist.** `CKSharingSupported=YES`; `configurationForConnecting`; `ShareSceneDelegate` (warm + cold); `PendingShareInbox`; drain in `SimmerSmithApp.task`. *Accept:* manual — a share link launches/foregrounds the app and metadata reaches AppState (warm + cold).
- **T5 — `acceptHouseholdShare(metadata:)` boot + fetch + repos + marker.** §5 sequence incl. the start()-already-fetches retry framing, the warm-accept owner→participant swap (stop old engine, keep `engine-state.json`), re-entrancy dedup. *Files:* `AppState+Recipes.swift` (new method ~near 23; repo wiring 71-157). *Accept:* device-gated (Task 9 steps 3-6); headless re-entrancy guard test.
- **T6 — Adopt-across-launches + the accept-before-mint invariant.** `ensureHouseholdSession` early branch checks **PendingShareInbox AND the marker** before private-zone discovery. *Files:* `AppState+Recipes.swift:23-75`. *Accept:* unit (e) incl. **zero-zone cold-accept never mints**.
- **T7 — Retire Fly invite/join + hard-gate merge.** *Files:* `SettingsView.swift:1332-1454`, `InvitationSheet.swift`, `AppState+Household.swift:67-82`. *Accept:* unit (f); Fly auth/import/rename intact.
- **T8 — Headless unit suite.** Land units (a)-(g). *Accept:* all green via `swift test` + app build.
- **T9 — Two-real-device human gate.** §10 steps, each `[?] awaiting human verify`, recorded per step in the PR. Hard gate.

## 13. Out of scope (v1)

N-member (>1 partner) · un-adopt/leave flow · merging a participant's solo data · owner-only/read-only participant modes · migrating the debug ShareHandoff URL-paste harness to production · per-record/per-type sharing · sharing the per-user NSPCKC plane.

## 14. Open risks / MUST-VERIFY-ON-DEVICE

- **Make-or-break:** the post-accept manual `fetchChanges()` is best-practice **inference**, not Apple-documented for CKSyncEngine. If a self-acceptance push arrives, the manual fetch is harmless; if not and it's omitted, the participant sees an empty household. Confirm on two devices.
- Zone-wide share + CKSyncEngine coexistence has **no official Apple sample** — the owner engine surfacing the share record back (filtered) is the highest-risk area.
- `sharedZoneID` from `metadata.share?.recordID.zoneID` is reasoned from primitives — verify on device; `allRecordZones()` fallback mitigates.
- `accept()` may return before the server creates the zone → first fetch can race empty → retry/backoff, tune timing on device.
- Cold-launch metadata is one-shot — the `PendingShareInbox` drain ordering vs `ensureHouseholdSession` is load-bearing (T6).
- Production schema + production APNs must be deployed before the gate, or participant fetch/steady-sync fails (ops, §11).

## 15. Adversarial review applied (critique `needs-revision` → fixed)

1. **Cold-launch ordering hole** — `ensureHouseholdSession` now checks PendingShareInbox **and** the marker before private-zone discovery; "zero-zone cold-accept never mints" is an explicit invariant + test (T6, §6).
2. **Don't edit the hierarchical share helpers in place** — T3 adds NEW zone-wide methods; `CloudKitDebugView`'s hierarchical round-trip is left intact.
3. **Softened "owner provably unchanged"** — §9 enumerates the three new device-gated owner-engine surfaces (share-create, filter, deletion split) and requires they be verified inert/benign; the deletion branch must not wipe the owner mirror (T2 acceptance).
4. **Warm-accept swap + re-entrancy + start()-already-fetches** — §5/§6 specify the owner→participant session swap (stop old engine, keep `engine-state.json`), the shared dedup guard, and that the post-accept fetch is a retry layered on `start()`'s existing fetch with a non-terminal raced `.offline`.

## 16. Confidence

- **HIGH** (grounded in read code): the Role/engine/owner-regression mechanics, per-scope state isolation, the Fly-retirement surface, "no production share exists today" (only `CloudKitDebugView` calls the share helpers), the default-role call-site preservation, and the `ownsZone` guards.
- **MEDIUM-HIGH** (device-gated, marked MUST-VERIFY): the participant boot+fetch seam — post-accept fetch necessity, `sharedZoneID` resolution, zone-revocation handling, and the zone-wide-share ↔ owner-engine coexistence.
- The engine being already scope-agnostic de-risks the two-engine claim — no separate `ParticipantHouseholdSession` is needed for v1.
