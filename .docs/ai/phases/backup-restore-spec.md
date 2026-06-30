# Backup & Restore — Spec

**Status:** approved design, pre-plan. 2026-06-30 (Opus). Motivated by the voice data-loss incident: feature
development can clear a user's meals/recipes; they want an in-app safety net to restore. **User-locked:**
automatic rolling snapshots + manual · **restore = recover (additive, never destroys)** · on-device + Files export.

**Goal:** A user can recover their household data (meals/weeks, recipes, pantry, events, …) from a recent
snapshot if a build clears or corrupts it — with zero risk that restoring destroys newer data.

## 1. Architecture — generic store-level snapshot

All household data already flows through one serializable primitive: `HouseholdRecordValue`
(`SimmerSmithCloudKit/Sources/HouseholdRecords/HouseholdRecordValue.swift`) — `{ type, recordName, scalars,
refs }` — for all 19 record types, via `HouseholdRecordCodec.encode/decode`
(`…/HouseholdRecords/HouseholdRecordCodec.swift`). So:

- **Snapshot:** `session.store.allRecords()` (`HouseholdLocalStore.allRecords()`) → for each, `HouseholdRecordType(rawValue: record.recordType)` then `HouseholdRecordCodec.decode(record, as: type)` → `[HouseholdRecordValue]` → JSON.
- **Restore:** JSON → `[HouseholdRecordValue]` → `HouseholdRecordCodec.encode(value, zoneID: session.zoneID)` → `session.engine.save(record)` (upsert) → `session.engine.sendUntilDrained()` → reload repos + re-mirror.

**Why generic (not domain-level WeekSnapshot/Recipe JSON):** one snapshot + one restore function cover **all 19
types** (week, weekMeal, weekMealSide, recipe, recipeIngredient, recipeStep, pantryItem, event/eventMeal/…,
baseIngredient/ingredientVariation, managedListItem, aliases, householdSetting) with **exact IDs + references
preserved** — no per-entity code, no "forgot type X," no re-link bugs. The domain approach is lighter to read
but incomplete (meals+recipes only) and re-mints/relinks. Precedent: `MigrationLedger` already enumerates
`store.allRecords()`.

**Excluded (v1, acceptable):** recipe **images** are `CKAsset`s, not scalar fields — not captured by
`HouseholdRecordValue`. They're regenerable via the existing "Generate missing images" (SettingsView ~237). Text
data (the stuff that matters) is fully covered. **Per-user profile/dietary** lives on the private plane (separate
from the household zone) — out of v1 scope; the household zone (the shared meals/recipes/pantry/events) is covered.

## 2. Data model + serialization (host-testable)

In **`HouseholdRecords`** (so the round-trip is `swift test`-able):
- Make `HouseholdRecordValue` + `ScalarValue` **`Codable`** (they're already value types; `HouseholdRecordType`
  is a `String` enum). MUST-VERIFY scalars encode losslessly (dates ISO8601, bool/int/double/string).
- `public struct HouseholdBackup: Codable { let schemaVersion: Int; let capturedAt: Date; let appBuild: String; let role: String; let records: [HouseholdRecordValue] }`.
- `enum BackupCodec`: `encode(HouseholdBackup) throws -> Data` / `decode(Data) throws -> HouseholdBackup`
  (`JSONEncoder`/`Decoder` with `.iso8601`). `schemaVersion` gates forward-compat (reject unknown major).

## 3. Snapshot + storage (app target, `AppState+Backup.swift`)

- `func snapshotHousehold() -> HouseholdBackup?` — guard `householdSession`; map `store.allRecords()` (skip the
  migration-receipt type, as `MigrationLedger` does) through the codec; stamp `capturedAt`/`appBuild` (from
  `CURRENT_PROJECT_VERSION`)/`role`.
- **On-device store:** `Application Support/SimmerSmithBackups/` (mirrors where `HouseholdSession` keeps engine
  state, `HouseholdSession.swift:111`). Filename `backup-<yyyyMMdd-HHmmss>.json`. Create dir lazily.
- `func writeSnapshot(manual: Bool)` — snapshot → `BackupCodec.encode` → write file → **prune to the last 14**
  (delete oldest). The prune (sort filenames, drop beyond N) is a **pure, host-testable** helper.
- `func listBackups() -> [BackupFile]` — `{ url, capturedAt, byteSize }` sorted newest-first (parse the date
  from the filename / read `capturedAt`).
- **Auto trigger:** in `SimmerSmithApp` launch `.task`, after `ensureHouseholdSession()` + the first sync, call
  `writeSnapshot(manual:false)` **at most once per calendar day** (guard on a `UserDefaults` last-snapshot-day
  key). Rolling 14-deep history is the real protection: even if today's build damages data, a prior day's
  snapshot (data intact) is restorable.

## 4. Restore — RECOVER (additive, never destroys)

`func restoreHousehold(from backup: HouseholdBackup) async throws`:
1. `try await session.engine.fetchChanges()` first — reconcile with the server so the upsert merges against
   current state (and the grocery/event field-merge resolver in `HouseholdSyncEngine` doesn't clobber a peer).
2. For each `record` in `backup.records`: `session.engine.save(HouseholdRecordCodec.encode(record, zoneID: session.zoneID))` — **upsert only**. We do NOT delete records present-now-but-absent-from-snapshot → restoring re-adds anything deleted + overwrites anything changed, but **never removes data added since**. (This is the user-locked "recover," not "exact replace.")
3. `try await session.engine.sendUntilDrained()` → push to CloudKit.
4. Reload repos + re-mirror (reuse `refreshHouseholdFromCloud`'s reload/mirror block, or call it).
- **Confirm before restore** (it writes to CloudKit). **Shared-household note:** restore writes to the active
  zone — for a participant that's the owner's shared zone, so recovering benefits both members (correct for
  shared data; surface this in the confirm copy).

## 5. Export / Import via Files

- **Export:** `func exportBackup(_ url: URL)` → SwiftUI `.fileExporter` (or `UIActivityViewController`) writes a
  chosen snapshot's `.json` to Files/iCloud Drive — a durable copy the user controls.
- **Import:** `.fileImporter` picks a `.json` → `BackupCodec.decode` → the same `restoreHousehold(from:)` path.
  Validate `schemaVersion`; surface a clear error on a bad/foreign file.

## 6. UI — `BackupRestoreSection` in Settings

Insert after the **Data** rows (Clear Local Cache / Reset Connection, SettingsView ~552), before Sign Out.
- **"Back up now"** → `writeSnapshot(manual:true)` + a brief confirmation.
- **List** of snapshots (date/time + size), newest first; tap → confirm sheet ("Recover from this backup? This
  re-adds anything missing and won't delete newer changes.") → `restoreHousehold`.
- **"Export to Files"** (per snapshot or the latest) and **"Restore from a file…"** (`.fileImporter`).
- Reuse `SMColor`/`SMFont`/`SmithSectionHeader("backups")`. Disable actions while a restore is in flight.

## 7. Error handling

Snapshot write failure → surface, don't crash (auto-snapshot is best-effort, silent-log). Restore failure
(fetch/send) → clear message, keep the snapshot file, leave data as-is (upsert is re-runnable). Empty/garbage
import file / wrong `schemaVersion` → "This isn't a SimmerSmith backup" (no write). No household session →
disable the section with a hint.

## 8. Test plan

**Host (`swift test`, HouseholdRecords):** `HouseholdRecordValue`/`ScalarValue`/`HouseholdBackup` Codable
round-trip (all scalar kinds + refs, date fidelity); `BackupCodec` encode→decode equals input; `schemaVersion`
mismatch rejected; the **prune-to-N** helper. **Device-gated human gate (T-final):** on-device — Back up now →
delete a few meals (and/or a recipe) → Restore → the deleted meals/recipe reappear and nothing newer is lost;
auto-snapshot file exists after a launch; Export to Files produces a readable `.json`; Import restores from it.

## 9. Task breakdown (ordered, headless-first)

- **T1** — `HouseholdRecordValue`/`ScalarValue` Codable + `HouseholdBackup` + `BackupCodec` in HouseholdRecords + round-trip tests. *Accept:* package builds; round-trip tests pass.
- **T2** — `AppState+Backup.swift`: `snapshotHousehold()` + on-disk write + **prune(keepLast:14)** + `listBackups()`; pure prune test. *Accept:* writes a file; prune keeps newest 14.
- **T3** — `restoreHousehold(from:)` (fetch → upsert → drain → reload/mirror). *Accept:* compiles; device gate proves recovery.
- **T4** — Auto-snapshot trigger (launch `.task`, once/day guard). *Accept:* a snapshot file appears after a launch.
- **T5** — Export (`fileExporter`) + Import (`fileImporter` → restore). *Accept:* round-trips a `.json` through Files.
- **T6** — `BackupRestoreSection` UI (back-up-now, list, restore-with-confirm, export, import). *Accept:* builds; flows present.
- **T7** — Human gate (on-device recover test, per §8). `[?] awaiting human verify`.

## 10. Out of scope (v1)

Recipe images (CKAsset; regenerable); per-user profile/dietary (private plane); per-entity selective restore
(v1 restores the whole snapshot, additively); exact-replace restore (only "recover"); encrypted/passworded
backups; automatic Files/iCloud-Drive upload (export is manual); cross-household import (a backup restores into
the current household zone).

## 11. Confidence

- **HIGH** on the architecture: `store.allRecords()` + `HouseholdRecordCodec` + `engine.save`/`sendUntilDrained`
  are verified seams (Agent-mapped with file:line; `MigrationLedger` precedent). The generic raw-store snapshot
  is complete + ID-faithful.
- **MUST-VERIFY-IN-CODE:** `HouseholdRecordValue`/`ScalarValue` Codable conformance compiles + round-trips
  losslessly; `sendUntilDrained` pushes restored records; the participant-zone restore writes to the shared zone.
- **Device-gated:** the actual recover round-trip (delete → restore → reappear) — the T7 human gate is the proof.
