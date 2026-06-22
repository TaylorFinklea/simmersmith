# SP-C — Factory Reset + re-import (clean slate)

> 2026-06-22. On-device build 118/119: ~14 `household-*` zones accumulated from repeated
> early-build minting; data scattered across zones; discovery (even richness-ranked) lands on a
> zone without the user's recipes. Decision (user): stop patching the corrupted multi-zone state —
> WIPE everything CloudKit-side and re-import fresh from Fly (Fly still has all data; migrations
> COPY, never move). Deliver one "Start Fresh from Fly" action.

## 0. Goal
One destructive, confirmed action that returns the user to a single clean household with their
data re-imported from Fly: **wipe all CloudKit household zones + the private plane + local state +
all receipts → mint ONE fresh household → re-import recipes+weeks+events+pantry from Fly under a
single one-shot Apple→Fly auth.**

## 1. What already exists (reuse, from the map)
- **Teardown:** `AppState.teardownHouseholdSession()` → `session.clearState()` deletes the sync-engine
  token file `~/Library/Application Support/HouseholdSync/engine-state.json`; releases all repos.
  `clearLocalCache()` clears the SwiftData cache + AppState in-memory props. `clearReminderMappings()`.
- **Mint/launch:** `householdID` is NEVER persisted (no cached-id landmine). `ensureHouseholdSession()`
  → `resolveHouseholdID()` → accountStatus preflight → `discoverWithZeroZoneRetry()` → zero zones ⇒
  MINT (UUID + ensureHouseholdZone + ensureHouseholdProfile). So after a wipe, a fresh launch/`ensure`
  mints exactly one household. RootView reacts to `householdLaunchPhase` (.resolving/.ready/.iCloudUnavailable).
- **Zone cleanup:** `HouseholdZoneProvisioner.deleteEmptyHouseholdZones(keeping:)` (just added) — deletes
  only ≤1-record zones. NO delete-ALL path (gap).
- **Migration loaders (all COPY from Fly, receipt-gated, idempotent):**
  `RecipeMigrationLoader.migrateRecipesIfNeeded(session:apiClient:)` (receipt `migrated:recipes` in the
  household zone); `WeekMigrationLoader`/`EventMigrationLoader` (`migrated:weeks`/`migrated:events`,
  zone records); `PantryProfileMigrationLoader` (`pantry-profile` receipt in the PRIVATE plane).
- **Apple→Fly one-shot auth:** `AppState.importWeeksFromFly(appleIdentityToken:)` mirrors the pattern —
  Apple identity token → `apiClient.signInWithApple()` → a temporary Fly JWT → run the loader → discard
  the JWT. `ImportWeeksSection`/`ImportEventsSection` in SettingsView drive it with `SignInWithAppleButton`.
- **GAP — recipe import is NOT re-triggerable:** recipes only migrate on first-launch inside
  `ensureHouseholdSession` (and post-identity there's no everyday Fly JWT), so a fresh mint will NOT
  auto-restore recipes. The clean-slate flow must run the recipe loader explicitly under the one-shot JWT.

## 2. Components to build
| Component | New? | Responsibility |
|---|---|---|
| `deleteAllHouseholdZones()` | new (HouseholdZoneProvisioner) | delete EVERY `household-*` zone in the private DB (no keeping, no record-count filter) → returns deleted ids. Mirror `deleteEmptyHouseholdZones` minus the filter. |
| `clearPrivatePlane()` | new (PrivatePlaneStore or HouseholdSession) | delete ALL private-plane @Model instances (PrivateMigrationReceipt, PrivateDietaryGoal, PrivateIngredientPreference, PrivateProfileSetting, PrivatePreferenceSignal, PrivateAssistantThread/Message) + `save()` so NSPCKC propagates the deletes to the user's private DB. Clears the `pantry-profile` receipt + stale per-user data. |
| `startFreshFromFly(appleIdentityToken:)` | new (AppState) | THE orchestration (below). |
| `StartFreshSection` (Settings) | new (SettingsView) | a destructive "Start Fresh from Fly" section: explains it wipes + re-imports, a confirmation dialog, then `SignInWithAppleButton` (mirror ImportWeeksSection's auth) → calls `startFreshFromFly`; shows progress + a result summary (counts per feature). |
| recipe re-import path | new (AppState) | a callable recipe import under a provided JWT (factor from `migrateRecipesIfNeeded`) so the orchestration can run it — and optionally an `ImportRecipesSection` for standalone re-import parity. |

## 3. `startFreshFromFly(appleIdentityToken:)` — the orchestration (the load-bearing part)
In order, each step surfaced to the UI as progress; abort with a clear error on failure (never leave a
half-wiped state silently):
1. **Auth first** (fail before wiping if the token is bad): `jwt = try apiClient.signInWithApple(appleIdentityToken)`; set it on the apiClient (a temporary authed client). If this fails → STOP, nothing wiped.
2. **Wipe CloudKit:** `provisioner.deleteAllHouseholdZones()` (every household zone) + `clearPrivatePlane()`.
3. **Wipe local:** `teardownHouseholdSession()` (clears the engine token file + repos) + `clearLocalCache()`.
4. **Mint fresh:** `await ensureHouseholdSession()` → discovery finds zero zones → mints ONE clean household; wait for `householdLaunchPhase == .ready`.
5. **Re-import (with the JWT'd apiClient, into the fresh session), in order, each idempotent:** recipes →
   weeks → events → pantry-profile (run the loaders directly; the fresh household has no receipts so each
   runs). Collect per-feature counts.
6. **Discard the JWT** (drop the temporary authed client; the everyday client stays unauthenticated).
7. **Reload** all repositories; return a summary.
Idempotent + re-runnable: if it fails mid-import, re-running re-wipes + re-imports (receipts make each
loader a safe retry; the wipe makes the whole thing safe to repeat).

## 4. Verification
- **Headless:** `deleteAllHouseholdZones` zone-selection logic (which zone names are targeted — all
  `household-*`, nothing else); `clearPrivatePlane` deletes every model type (in-memory store, sync off).
- **On-device (the real test):** Settings → "Start Fresh from Fly" → confirm → Apple sign-in → wipe +
  re-import → **Forge shows the recipes**, Weeks/Events/Pantry populated, ONE household (no "leftover
  households" banner), relaunch stays on the one household. Re-running it is safe (idempotent).

## 5. Risks
- **Destructive** — must confirm; auth-first (don't wipe if auth fails); idempotent/re-runnable.
- **Private-plane delete propagation** — NSPCKC deletes propagate to the private DB on next sync; the
  local clear is immediate (the receipts gate re-import locally). Acceptable.
- **The wipe→mint race** — strictly sequential (delete all, THEN ensure/mint); no concurrent zone create.
- **No new CloudKit types / no schema change.** Recipe loader must run under the explicit JWT (the
  first-launch auto-path can't, post-identity).
