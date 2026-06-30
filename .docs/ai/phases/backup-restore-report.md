# Backup & Restore — Report

**Status:** built + shipped (build 145); recover device gate pending. 2026-06-30 (Opus).
Spec: `backup-restore-spec.md`. Decisions: `decisions.md` (2026-06-30).

## What shipped

An in-app safety net (Settings → **Backups**) after the voice data-loss incident. Snapshots the whole household
to JSON and recovers from any snapshot — additively, never destructively.

- **Snapshot (T1/T2):** every household-zone record → `HouseholdRecordCodec.decode` → `HouseholdRecordValue` →
  `HouseholdBackup` → JSON. `HouseholdRecordValue`/`ScalarValue`/`HouseholdRecordType` made Codable;
  `BackupCodec` (ISO8601, rejects newer schema); `BackupFilePolicy` (filename↔date + keep-newest-N).
- **Restore = RECOVER (T3):** fetchChanges → for each backup record, `apply` onto the existing store record
  (preserve change tag) or fresh-encode a deleted one → `sendUntilDrained(30)` → reload+mirror. Never deletes
  records absent from the backup. Skips overwriting field-merger types (grocery/event live state).
- **Auto + manual + Files (T4/T5/T6):** `maybeAutoSnapshot` (once/day on launch, keep 14); `BackupRestoreSection`
  UI (Back up now, dated list, tap-to-recover with confirm, swipe-delete, ShareLink export, `.fileImporter`).

New code: `HouseholdRecords/{HouseholdBackup,BackupFilePolicy}.swift` + Codable on the record types;
`AppState+Backup.swift`; `Features/Settings/BackupRestoreSection.swift`; `HouseholdRecordCodec.apply(_:onto:)`
extracted.

## Process

Brainstorm (3 decisions: automatic+manual · recover-additive · on-device+Files) → 2 parallel data-layer
explorations (confirmed the generic store-level snapshot is the clean seam) → spec → Opus implemented T1-T6
headless-first → caught the change-tag-conflict issue mid-build (restore must preserve tags like the repos) →
4-dimension adversarial review (10 findings, 3 critical) → fixed → shipped 145.

## Verification

- **Headless (run):** 43 HouseholdRecords tests — backup round-trip fidelity (Date stays Date, refs, newer-schema
  rejection) + retention policy (filename↔date, keep-N).
- **Build:** app compiles clean.
- **Adversarial review:** 10 findings; 3 criticals fixed (merger clobber, participant shared-zone warning, drain
  completeness) + I3/I4/I6; I5/I2/M1 deferred with rationale.
- **Device-gated (the gate):** the recover round-trip (back up → delete a meal → recover → it returns; a newer
  meal survives a second recover) — only a real device + CloudKit proves it. Report:
  `simmersmith/backup-restore-device-test`.

## Deferred / follow-ups

- I5: move the auto-snapshot encode/write fully off-main (runs post-interactive today; fine for normal household
  sizes — needs HouseholdBackup Sendable + a detached write).
- I2: surface a decode type-mismatch (only matters under CloudKit corruption).
- Recipe images (CKAsset) in backups; per-user profile/dietary (private plane); exact-replace restore mode;
  selective per-entity restore. All out of v1 scope (spec §10).
