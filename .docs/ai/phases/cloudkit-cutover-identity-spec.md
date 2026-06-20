# SP-C — CloudKit cutover, slice 2: Identity (no sign-in, iCloud-native)

> Design spec. Brainstormed + approved 2026-06-19. Second cutover slice (after Recipes, merged).

## 0. Goal + frame

Make the app's identity the user's **iCloud account**: no sign-in screen, no Fly auth token, `householdId`
discovered from CloudKit. The app opens straight into the CloudKit data.

**Decided (brainstorm 2026-06-19):**
- **Find `householdId` by discovering it from CloudKit** (list the private DB's zones, find `household-*`) —
  reinstall-proof (data persists server-side), truly iCloud-native. NOT cached-from-Fly.
- **Drop Fly now — CloudKit-only, incremental.** No silent re-auth. Recipes works on CloudKit; every
  not-yet-cutover feature (Weeks / Grocery / Events / Pantry / Profile / all AI) shows a **"coming soon"**
  state until its own slice. The app is an intentional CloudKit-only WIP — Taylor isn't using it for daily
  meal-planning yet (Savanne is on the old Fly build, so the shared Fly data is safe + in active use).
- **New install with no zone → silently auto-create** a CloudKit-native household.
- **"Coming soon" treatment** → a minimal placeholder per non-Recipes tab (no heavy UX investment).

**Non-goals (explicit):** AI providers (separate AI track), the CKShare participant-join (Savanne) flow,
migrating Weeks/Grocery/Events data (each feature slice migrates its own data later — see §6).

## 1. Architecture

The launch identity flips from "Fly token present?" to "CloudKit household resolved?".

### 1.1 Household discovery (new capability)
Add zone-discovery to the CloudKit layer (extend `HouseholdZoneProvisioner` or a new `HouseholdResolver`):
- `func discoverHouseholdID() async throws -> String?` — fetch the private DB's record zones
  (`CKDatabase.allRecordZones()` / a fetch-all-zones op), find a zone whose name matches the
  `household-<id>` convention (`HouseholdZoneProvisioner.zoneName` is the authority — parse the id back out),
  return the id. Multiple/zero handled: zero → nil; multiple → pick deterministically (the spec's §1.2 rule).
- The household zone lives in the user's **private** CloudKit DB (owner). (Shared-DB/participant discovery is
  the participant slice — out of scope.)

### 1.2 Launch resolution (`HouseholdSession` owns it)
On launch (iCloud account available), resolve the household with NO Fly call:
1. `discoverHouseholdID()` → if found, that's the household. (Taylor's case — recipes already there.)
2. If nil → **mint a new household**: generate a fresh `householdID` (UUID), `ensureHouseholdZone`, write a
   `HouseholdProfile` (default name), use it. Silent — no UI.
3. Construct `HouseholdSession(householdID:)` + `start()` exactly as today (Recipes slice), then the
   repositories. The only change is WHERE the `householdID` comes from (discovery, not `refreshHousehold`/Fly).
- Multiple `household-*` zones (shouldn't happen for an owner, but be safe): pick the one with the most
  records / the one bearing a `HouseholdProfile`, deterministically; log the rest. Never guess silently into
  an empty zone when a populated one exists.

### 1.3 The launch gate (`RootView`)
`RootView` currently shows `MainTabView` iff `appState.hasSavedConnection` (Fly token), else `SignInView`.
Change: gate on **CloudKit-household readiness** — once `HouseholdSession` has resolved/created a household,
show `MainTabView`; while resolving, a brief launch/loading state; if iCloud is unavailable, a clear
"Sign in to iCloud in Settings" message (NOT the Fly sign-in screen). The Fly-token gate is removed.

## 2. Remove the sign-in UI
- Delete (or hard-disable) `SignInView` and its entry points: Sign in with Apple, Sign in with Google, the
  "Use a self-hosted server" option. Remove the `RootView` branch that shows it.
- Keep the `DebugGate` "CloudKit checks (debug)" affordance reachable (Settings, gated as today).
- The Apple/Google sign-in *code paths* in AppState (`signInWithApple`/`...Google`/manual-connection) become
  dead for the everyday flow — leave the methods but unreferenced from UI, OR delete the UI wiring only
  (keep the methods for a future one-time migration auth — see §6). Decide in the plan; lean: keep the methods,
  delete the UI.

## 3. Drop Fly from the everyday flow + "coming soon"
- Introduce a single source of truth for "this build is CloudKit-only": e.g. `AppState.isCloudKitOnly` (true).
- **Recipes** (cut over) works unchanged.
- **Non-cutover features** (Weeks / Grocery / Events / Pantry / Profile / AI): their tab/section entry points
  show a minimal **`ComingSoonView`** ("Coming to CloudKit soon") instead of calling Fly. Gate at the VIEW
  entry (so the Fly methods aren't even invoked → no 401s, no error banners). Keep it lightweight.
- Do NOT rip out the Fly `apiClient` or the per-feature AppState methods — they stay (dormant) for the
  per-slice migrations (§6). Just stop the everyday flow from calling them.

## 4. Error handling
- iCloud account not available (signed out of iCloud on the device): a clear, friendly screen directing to
  iOS Settings → iCloud; retry on foreground. NOT a crash, NOT the Fly sign-in.
- Discovery failure (network): retry with backoff; show the launch/loading state; surface a soft error if it
  persists. The household is owner-private, so a transient CloudKit hiccup shouldn't strand the user.
- New-household creation failure: surface + retry; don't proceed into the app without a resolved household.

## 5. Verification
- **Headless:** the `household-<id>` name parse/round-trip (`zoneName(householdID:)` ↔ discovery parse) as a
  pure unit test (id with hyphens/UUID survives).
- **On-device (TestFlight, the proven gate):** (1) fresh launch on Taylor's account → **no sign-in screen** →
  lands in the app → **Recipes tab shows the migrated recipes** (zone discovered, correct household); (2) the
  other tabs show "coming soon"; (3) force-quit + relaunch → still no sign-in, same data; (4) a debug check
  ("Identity — household discovery") asserts `discoverHouseholdID()` returns the expected id. New-account path
  (auto-create) is hard to test on Taylor's existing account — verify the create branch headlessly / on a
  fresh sim account if practical, else code-review it.

## 6. Data on Fly (what happens to it)
Recipes already migrated. Weeks/Grocery/Events/Pantry/Profile still live on Fly and **stay there** — Savanne's
old build is actively using them, so they're safe. Dropping everyday Fly auth does NOT destroy the ability to
migrate later: when a future feature slice cuts over, IT performs a one-time Fly pull (a one-shot Apple auth
just for that migration, then discarded), reusing the dormant `apiClient` + the `HouseholdMigrationRunner`
pattern. The final couple-cutover (Savanne → CloudKit via CKShare) is the participant slice. No data is
stranded; it's deferred, with the retrieval path intact.

## 7. Risks / landmines
- **Don't auto-create a second household when one exists** — discovery must be robust (§1.2). Minting a new
  zone when the user already has `household-<flyId>` would orphan their recipes. Discovery-before-create is
  load-bearing.
- **iCloud-not-signed-in** must degrade to a friendly prompt, not the deleted Fly screen and not a crash.
- **The recipes migration receipt** lives in the discovered zone — discovery must find THAT zone (the one the
  Recipes slice migrated into) so the receipt + recipes are seen. (They share the same `householdID`.)
- **No new record types** this slice → no schema deploy needed.
- Keep the Fly migration code paths compiling (dormant) — a future slice needs them.

## 8. Sequence after this slice
Identity (this) → Weeks + WeekMeals + Grocery (with its own Fly→CloudKit data migration) → Events → Pantry/
Profile → AI providers track → CKShare participant join (Savanne) → SP-D (Fly retired).
