# CloudKit SP-A — Data-Plane Migration Design Spec

> Status: **draft, adversarially reviewed — fixes folded inline + summarized in §11; awaiting user review** · Authored 2026-06-15 (Opus)
> Parent: `cloudkit-migration-spikes-spec.md` (Spike 1 gated this) ·
> `cloudkit-migration-spikes-report.md` (Spike 1 verdict: GO on `CKSyncEngine`
> for grocery/event, LWW elsewhere).
> Scope: the **data plane only** (SP-A). AI tiering is SP-B; on-device platform
> is SP-C; migration/retirement execution is SP-D; credits gateway is SP-E. This
> spec defines the SP-A container/zone topology, sharing redesign, identity
> migration, two-tier sync boundary, the field-merge resolver, client-enforced
> invariants, public-catalog strategy, the iOS-26 AI abstraction seam, and a
> phased build sequence. It synthesizes the per-entity CloudKit mappings produced
> by 9 reader agents.

## 0. Locked decisions this design assumes (2026-06-15)

- **Target iOS 26 NOW** (in-place migration of the existing SwiftUI app). Upgrade
  on-device AI to AFM 3 20B + PCC at iOS 27 GA.
- **iCloud account IS the identity.** Apple/Google sign-in, the session-JWT, and
  the `users` table are dropped. Per-user data is owned by the iCloud user;
  household data is a `CKShare`.
- **Data plane → CloudKit**: PRIVATE db (per-user), SHARED db via `CKShare`
  (per-household), PUBLIC db (read-mostly global reference catalog).
- **Two-tier sync** (Spike 1): sticky-merge data (grocery smart-merge, event↔week
  grocery merge) MUST ride `CKSyncEngine` + a custom field-merge resolver; blanket
  `NSPersistentCloudKitContainer` last-writer-wins (LWW) corrupts the sticky
  fields. Plain CRUD data rides `NSPersistentCloudKitContainer`.
- **Dropped, not migrated**: Claude.ai MCP connector + OAuth AS + web SSO;
  freemium/entitlement/`UsageCounter` server gating; admin/cost-telemetry plane;
  server-side push scheduler (→ on-device `UNCalendarNotificationTrigger`); App
  Store Server Notification webhook (→ on-device StoreKit 2 entitlement checks);
  the off-device pricing/scraping pipeline (`RetailerPrice`, `PricingRun`).
- **`LargeBinary` image/photo bytes → `CKAsset`** file-refs (1 MB CKRecord limit),
  never inline record fields. Only the recipe-image / recipe-memory group has them.
- **AI is provider-agnostic and mostly off-server**: on-device Foundation Models
  (free), BYO-key cloud, or an optional credits gateway (the only optional server).

---

## 1. Container + zone topology

### 1.1 One CloudKit container, three databases

A single CloudKit container (provisioned under the dev team — see §9) hosts:

| Database | Owner | Contents | Sync stack |
|---|---|---|---|
| **PRIVATE** | the iCloud account | per-user-only data **and** the canonical home of each household zone the user *owns* | mixed (see §4) |
| **SHARED** | n/a (a view) | the household zones the user has *accepted a `CKShare` into* (owner's zones surfaced read/write to participants) | mixed (see §4) |
| **PUBLIC** | the curator identity | global read-mostly catalog | read-only on device; curator writes out-of-band (§8) |

Key CloudKit fact that drives everything: **a `CKShare` shares a ZONE, not a
record.** Sharing the household root record shares its entire custom zone. So all
household-shared records for one household must live in **one custom zone**.

### 1.2 The household zone (the central structural unit)

A **household = one custom `CKRecordZone`** created in the owner's PRIVATE db,
root-shared via a single `CKShare`. Every household-scoped record — across all
entity groups — lives in that one zone so the single share covers the whole graph:

```
PRIVATE db (owner)                          SHARED db (each participant)
└── HouseholdZone (custom, CKShare root)     └── HouseholdZone (same zone, surfaced)
    ├── HouseholdProfile      (share root)        … identical records, read/write
    ├── HouseholdSetting*     (KV)                   per participant permission …
    ├── Week ─┬─ WeekMeal ─┬─ WeekMealSide
    │         │            └─ WeekMealIngredient
    │         ├─ GroceryItem
    │         ├─ WeekChangeBatch ─ WeekChangeEvent
    │         └─ FeedbackEntry
    ├── Recipe ─┬─ RecipeIngredient
    │           ├─ RecipeStep (self-ref substeps)
    │           ├─ RecipeImage   (CKAsset)
    │           └─ RecipeMemory* (optional CKAsset)
    ├── Event ─┬─ EventAttendee (→ Guest)
    │          ├─ EventMeal ─ EventMealIngredient
    │          ├─ EventGroceryItem
    │          └─ EventPantrySupplement (→ Staple)
    ├── Guest          (roster root, outlives events)
    ├── Staple / pantry records
    ├── HouseholdTermAlias
    └── BaseIngredient(household-tier) ─ IngredientVariation(household-tier)
```

**One household = one zone = one `CKShare`.** Cross-group coordination on this is
mandatory: if any household-scoped entity group is modeled in a *different* zone,
that group will silently not be shared and the household fractures. The zone
identity replaces every Postgres `household_id` FK/WHERE clause — "belongs to this
household" becomes "lives in this household's zone." There is no `household_id`
column on any record.

### 1.3 Per-user zone (PRIVATE-only data)

Per-user data that is **not** shared with the household lives in the owner's
PRIVATE db (default zone or a dedicated `PrivateUserZone`), never in the household
zone:

- `ProfileSetting` (KV), `DietaryGoal` (singleton), `PreferenceSignal`,
  `IngredientPreference` (per-user ranked brand/allergy choices — explicitly NOT
  shared; one member's allergy is their own).
- `AssistantThread` + `AssistantMessage` (transcript; filtered by `user_id`
  today, never `household_id`).

Records in this zone are **never** placed in or referenced into another
household's zone. Cross-database soft references (e.g. `AssistantThread.linked_week_id`
→ a SHARED Week) are stored as **string record-names, not CKReferences** —
CloudKit references cannot cross databases.

### 1.4 Public zone

The PUBLIC db holds the global catalog (default public zone, curator-owned):
approved-tier `BaseIngredient` (household_id-IS-NULL rows) + their global
`IngredientVariation`, `NutritionItem`, `IngredientNutritionMatch`,
`RecipeTemplate` (built-ins), `ManagedListItem`. Clients **read** a working subset
(cache the common head, `CKQuery` the long tail on cache-miss); only the curator
writes (§8).

---

## 2. Household sharing redesign

### 2.1 The model

- **"Your data"** = your PRIVATE db.
- **A "household"** = a custom shared zone *you own* + a `CKShare` rooted on its
  `HouseholdProfile` record.
- **Joining** = accepting the `CKShare` (the zone appears in your SHARED db).
- **Invitation** = the `CKShare.url` (or `UICloudSharingController`), accept-once,
  revocable via `removeParticipant`.

The Postgres `households` row **collapses into CloudKit primitives** — it is NOT a
record you author. There is exactly one app-authored root record per household,
`HouseholdProfile`, which exists only because `CKShare` requires a `rootRecord` and
because the display name should sync via normal record sync (mirrored to
`CKShare[.title]`). `households.id` → the zone's `CKRecordZoneID`/`CKShare.recordID`;
`households.created_by_user_id` → the zone-owner participant; `households.name` →
`HouseholdProfile.name` + `CKShare.title`.

### 2.2 Day-one-shared — NO solo-then-merge re-keying

**Every household is born shared**, even a household of one. On migration/first
launch the owner's device creates the custom zone + a `CKShare` on
`HouseholdProfile` immediately (the share need not be *surfaced* until the user
actually invites someone). This deletes the entire legacy
`create_solo_household` → `merge_solo_into` / `claim_invitation` re-keying path:
there is never a solo-zone whose records must be re-pointed into a shared zone
when a second member joins. The zone is share-ready from birth.

**Owner-two-devices zone-creation race (must design around):** "first launch
creates the zone" forks the household if the owner's *second* device launches
before the first device's zone+share has propagated — it would mint a **second**
household zone, splitting the data. Zone creation must be a deterministic
discover-then-claim: **query the PRIVATE db for an already-owned household zone
before creating one**, and use a deterministic zone name (derived from the migrated
`households.id`, or a fixed per-account well-known name) so two devices racing
converge on the same zone instead of two. This is distinct from — and not covered
by — the single-household-per-user share-accept enforcement (§2.4).

### 2.3 Owner / participant model

- **Owner** = the zone owner. CloudKit makes this structurally the only `.own`
  role and enforces it; the owner's `HouseholdProfile` lives in their PRIVATE db.
- **Participant** = `.readWrite` `CKShare.Participant`. `household_members` is
  **dropped as a record type** — CloudKit owns the participant roster natively
  (`role` → permission, `joined_at` → acceptance time, add/remove →
  `addParticipant`/`removeParticipant`). Authoring a parallel member record would
  double-bookkeep identity CloudKit already enforces.
- **Invitations** dropped as a record type — `household_invitations`
  (code/claim/TTL) → `CKShare` URL lifecycle. The one behavior CloudKit does NOT
  replicate is the 7-day TTL; if still required, the client tracks issuance and
  rotates/revokes the share URL itself (not a record).

### 2.4 Hard edges to design around (carry as risks into the plan)

- **Single-household-per-user** (Postgres `uq_household_members_user`): CloudKit
  will let a user accept multiple household shares. The client MUST enforce "one
  active household" — on accepting a new share, leave the prior one first (or
  surface a picker). This invariant is relied on by every `get_household_id` call
  site today.
- **Ownership transfer has NO CloudKit primitive** — zone owners are immutable.
  "Transfer" = recreate-zone-under-new-owner + re-share + re-migrate the whole
  graph (expensive, invalidates the share URL), OR pin hosting to the original
  owner's account permanently. **Decide this in Phase 2** before building member
  flows.
- **Owner-cannot-leave-without-transfer / only-owner-removes-others** are app
  logic — removing yourself from a zone you own deletes it for everyone.
- **Member write permission** to settings/shared content must be validated
  Spike-1-style (a record private-for-owner / shared-for-member must accept member
  writes), or members regress to read-only.

---

## 3. Identity migration

### 3.1 iCloud user replaces `apple_sub` / `google_sub`

Identity is the iCloud account. There is no user table, no `user_id` column on any
record. Where a *real actor* must still be named (e.g. `GroceryItem.checked_by_user_id`
= "who checked this off," genuine shared-household UX), store the iCloud
`userRecordID` / `CKUserIdentity` (or a display name), resolved via
`CKUserIdentity`. Where the old `user_id` only meant ownership (most cases), it is
**dropped** — ownership is implicit in PRIVATE-db placement or zone membership.

### 3.2 The one-time per-household export → import

Migration runs **once per user**, on first iOS-26 launch, while the legacy
auth/JWT bridge still exists (this is the last use of the old sign-in — it delivers
the right bundle to the right iCloud account, then the auth plane is retired in
SP-D):

1. **Server export** (existing per-`household_id`/`user_id` query paths): emit a
   signed per-household bundle = `HouseholdProfile{name,created_at}`, all
   `household_settings`, and the full FK-scoped shared graph (Weeks+subtree,
   Recipes+children+images/memories, Events+subtree, Guests, Staples, aliases,
   household-tier catalog rows) — plus a per-user bundle (profile settings minus
   AI secret keys, dietary goal, preference signals, ingredient preferences,
   assistant threads+messages).
2. **Identity remap**: `household_id` → the zone/share identity (no column);
   `created_by_user_id` → the iCloud account running the import = the owner;
   real-actor fields (`checked_by_user_id`) → iCloud `userRecordID`/display name
   else dropped.
3. **Client import**, keyed by **preserving original PKs as `CKRecord.recordName`**
   so cross-references and on-device match keys keep working:
   - **Solo household** (the common case): the device creates one custom zone in
     its PRIVATE db, writes `HouseholdProfile` + settings + the whole graph, and
     creates a (un-surfaced) `CKShare` so it's share-ready with no later re-key.
   - **Multi-member household**: ONLY the current Postgres *owner's* device imports
     (it becomes the CloudKit zone owner), creates the zone+share, and pre-adds
     other members as participants matched by the email/identity the dropped users
     table held (via `UICloudSharingController`). Non-owner members import NOTHING
     — they receive the household by accepting the share; it appears in their
     SHARED db.
   - **Per-user PRIVATE data** imports into the signing-in user's PRIVATE db.
4. **Wire parent CKReferences** during import (Week→HouseholdProfile,
   WeekMeal→Week, RecipeIngredient→Recipe, …) so the graph is one shareable unit.
5. **Sticky fields migrate verbatim**: `is_user_removed` tombstones, `*_override`,
   `is_checked`/`checked_at`, `event_quantity`, and `EventGroceryItem.merged_into_*`
   pointers MUST round-trip — recomputing them on-device would double-count or
   strand zombie rows (the documented 3→6→9 hazard). This is the whole point of
   the sticky-merge model.
6. **Dropped at export**: `RetailerPrice`/`PricingRun` (pricing plane), `AIRun`
   (cost telemetry), `Subscription`/`ProcessedAppleNotification`/`UsageCounter`/
   `PushDevice`/`ImageGenUsage` (billing/push/telemetry), AI secret keys (provider
   keys now live in the device Keychain, never CloudKit), `household_invitations`
   (unclaimed invites abandoned). `Week.priced_at` survives as a scalar.

### 3.3 Cutover / coexistence (users mid-migration)

- **Idempotent imports** — keyed by reused PKs as `recordName`, NEVER append-only,
  so a user signing into a second device before the first sync completes does not
  double-seed. Re-running the import targets the same record names.
- **Import-complete sentinel** — write a per-bundle `MigrationReceipt` record
  (recordName = the household/user id) only after the *entire* bundle imports.
  Import is a query-then-write resume: on relaunch, if the receipt exists, skip; if
  absent, the import re-runs and upserts by recordName (a half-finished import never
  recomputes sticky fields — §3.2 step 5 — it only fills gaps). Without this an
  interrupted import (network/app-kill/asset-timeout) can't tell what it already
  wrote.
- **Migration-status ledger (server-side)** — the export endpoint records, per
  household, "export delivered + client confirmed receipt." SP-D may retire Postgres
  **only when the ledger shows every household migrated** — "all households exported"
  must be *knowable*, not assumed. Dormant users who never launch the iOS-26 build
  keep the coexistence window open; define an explicit policy (indefinite hold vs a
  comms-then-sunset date) rather than silently stranding them.
- **Coexistence window**: the FastAPI export endpoints + legacy auth stay live
  through SP-A so any not-yet-migrated user can still pull their bundle. Postgres
  tables are decommissioned in SP-D only after the migration-status ledger confirms
  completion (above).
- **Mid-billing users**: StoreKit 2 derives entitlement fresh on first launch
  (`Transaction.currentEntitlements`), so an active Apple sub is recognized
  on-device with no server hand-off; comp/admin-grant rows (no Apple receipt)
  cannot be reconstructed but are moot under "no forced payment" (verify no code
  path still consults a now-absent `Subscription` and fails closed).
- **Multi-member fragmentation risk**: if a non-owner member's recorded
  email/identity doesn't match an iCloud account, the owner can't pre-add them;
  they must accept a share URL out-of-band. Some households may need a manual
  re-invite.

---

## 4. The two sync-mechanism boundary

Spike 1 proved blanket LWW corrupts the sticky fields (tombstone resurrection,
`event_quantity` loss, override clobber). The app therefore hosts **two sync
mechanisms**.

### 4.1 Which record types ride which stack

**`CKSyncEngine` (field-merge resolver) — the sticky-merge family:**

| Record type | Why CKSyncEngine |
|---|---|
| `Week` | parent of `GroceryItem`; co-located so one stack owns the whole grocery graph |
| `WeekMeal`, `WeekMealSide`, `WeekMealIngredient` | grocery-regen inputs; slot-swap atomicity (§6) |
| `GroceryItem` | THE canonical sticky-merge case — tombstones, `*_override`, `is_checked`, `event_quantity` |
| `Event` | `manually_merged` pin + `auto_merge_grocery` policy field-merge; drives event↔week merge |
| `EventGroceryItem` | cross-aggregate sticky merge — `merged_into_*` pointers + additive `event_quantity` |
| `EventPantrySupplement` | additive quantity into the week's `event_quantity` |

**`NSPersistentCloudKitContainer` (LWW) — plain CRUD:**

| Record type | DB |
|---|---|
| `Recipe`, `RecipeIngredient`, `RecipeStep` | SHARED (household zone) |
| `RecipeImage`, `RecipeMemory` (CKAsset payloads) | SHARED |
| `Guest`, `EventAttendee`, `EventMeal`, `EventMealIngredient` | SHARED |
| `HouseholdProfile`, `HouseholdSetting`, `HouseholdTermAlias` | SHARED |
| `BaseIngredient`/`IngredientVariation` (household-tier) | SHARED |
| `WeekChangeBatch`, `WeekChangeEvent`, `FeedbackEntry` | SHARED (audit/feedback; write-once) |
| `ProfileSetting`, `DietaryGoal`, `PreferenceSignal`, `IngredientPreference` | PRIVATE |
| `AssistantThread`, `AssistantMessage` | PRIVATE |

**Dropped (no record):** `RetailerPrice`, `PricingRun`, `AIRun`, `Subscription`,
`ProcessedAppleNotification`, `UsageCounter`, `PushDevice`, `ImageGenUsage`,
`household_members`, `household_invitations`, the `Household` row.

**PUBLIC read-only (curator-written):** approved `BaseIngredient` + global
`IngredientVariation`, `NutritionItem`, `IngredientNutritionMatch`,
`RecipeTemplate` (built-in), `ManagedListItem`.

### 4.2 One zone, one stack — the critical resolution

Two sync stacks **cannot cleanly co-own one CloudKit custom/shared zone**
(`CKSyncEngine` and `NSPersistentCloudKitContainer` race on the same zone's change
token). But splitting the household into two zones breaks the
single-`CKShare`-per-household graph and atomic week sharing.

**Resolution (recommended): the household zone is owned by ONE physical stack —
`CKSyncEngine`.** The plain-CRUD household records (`Recipe*`, `Guest`,
`EventMeal*`, `HouseholdProfile`, `HouseholdSetting`, alias, audit, feedback,
household-tier catalog) ride the same `CKSyncEngine` as **inert pass-through
records**: the resolver simply applies last-writer-wins for them (no special field
merge), which is exactly their intended semantics. The per-record `syncMechanism`
in the entity mappings reflects **merge-semantics intent, not a physical stack** —
"NSPersistentCloudKitContainer" there means "LWW is correct," which the single
`CKSyncEngine` resolver honors by doing nothing special.

The PRIVATE-only per-user zone (profile/prefs/assistant) and the PUBLIC catalog
have no sticky-merge records, so they **can** use `NSPersistentCloudKitContainer`
(or plain `CKDatabase` reads for public) independently — they're separate
databases/zones, no token contention with the household `CKSyncEngine`.

Net: **one `CKSyncEngine` per household zone** (sticky merge for grocery/event,
LWW pass-through for the rest); `NSPersistentCloudKitContainer` for the per-user
PRIVATE zone; read-only cache for PUBLIC.

---

## 5. The reusable field-merge resolver

Generalize Spike 1's `groceryResolver` into one resolver the household
`CKSyncEngine` invokes on every incoming record change. It is the highest-risk
component (a naive resolver silently corrupts shopping lists — the Spike-1
finding). It must replicate, on-device and conflict-free, the entire
`regenerate_grocery_for_week` / `_apply_fresh_to_existing` and
`merge_event_into_week` / `unmerge_event_from_week` semantics that live
server-side today.

### 5.1 Per-field merge policy (the sticky fields)

Resolve **per field**, never whole-record, for sticky record types:

| Field family | Records | Merge rule |
|---|---|---|
| **Tombstone** `is_user_removed` | `GroceryItem` | **monotonic** — last-removed-wins; once true, a stale regen from another device may NEVER revert it to false (no resurrection). |
| **User overrides** `quantity_override`, `unit_override`, `notes_override` | `GroceryItem` | override wins over the auto `total_quantity`/`unit`/`notes`; a concurrent regen must not clobber a set override. |
| **Per-actor check state** `is_checked`, `checked_at`, `checked_by_user_id` | `GroceryItem` | household-shared; the **triple is resolved as a unit** (the write with the later `checked_at` wins all three) so they never tear. Spike 1 confirmed a single boolean converges under LWW, but per-field LWW could land `is_checked=false` from one device and `checked_by=Alice` from another — resolve them together, not independently. |
| **Event-owned additive** `event_quantity` | `GroceryItem`, `EventGroceryItem` | **writer-ownership** — ONLY the event merge/unmerge path writes it; the meal-regen path refreshes `total_quantity` but leaves `event_quantity` untouched. The resolver keeps the two writers from clobbering each other (field-level). |
| **Merge-trace pointers** `merged_into_week_id`, `merged_into_grocery_item_id` | `EventGroceryItem` | resolved together with the `event_quantity` they wrote; replay merge/unmerge so a regenerate-then-remerge race doesn't double-count and unmerge-to-zero self-deletes event-only rows without stranding zombies. |
| **Pin / policy** `manually_merged`, `auto_merge_grocery` | `Event` | `manually_merged` is a sticky pin — if device A pins while device B moves `event_date` or clears `auto_merge_grocery`, an LWW write must NOT silently unpin/auto-re-point. |
| **User-added / event-only rows** `is_user_added` | `GroceryItem` | untouchable by the regen writer; preserved through merge. |

All other fields on sticky records, and ALL fields on the pass-through records,
use last-writer-wins.

### 5.2 The aggregation match key (ported verbatim)

The resolver and the on-device regen MUST compute the **identical** grocery match
key the server computes in `_key_for_item` / `_key_for_row`:

```
key = (base_ingredient_id or normalized_name, locked_variation_id, unit, quantity_text)
```

If the on-device key differs even slightly, migrated rows won't match fresh
aggregations and the list duplicates. **Port the logic verbatim** (don't
re-derive) and cover it with tests against migrated data. **Guard:**
`locked_variation_id` is the variation id **only when `resolution_status ==
"locked"`** (`grocery.py:321-323`), else the empty string — keying on the
variation unconditionally duplicates every non-locked row. `dedupe_week_grocery`'s
`(normalized_name, unit)` collapse also moves on-device, with its **semantic keeper
policy** (§5.3), not a structural one. **`WeekMealIngredient`'s String(140)
content-hash (`normalized_name|unit|source`) is MUTABLE** — editing the line
changes the hash — so it must **not** be the `recordName`. Use a stable id
(preserved legacy PK / UUID) as `recordName`, and keep the content-hash as a
recomputed, queryable `matchKey` *field* the aggregation reads. Likewise `normalize_name` / `normalize_tag_list` must be ported verbatim
(recipe→catalog resolution and grocery merge both depend on identical
normalization).

### 5.3 Conflict-repair duties (beyond field merge)

- **Duplicate week** (`UNIQUE(household_id, week_start)`): on a conflict where two
  devices created the same `week_start`, deterministically merge into the lower
  `recordName` and re-parent its subtree to the survivor.
- **Duplicate grocery rows** (`dedupe_week_grocery`): the keeper choice is
  **semantic, not structural — port the server policy verbatim** (`grocery.py:794-805`):
  prefer the auto-aggregated row with `source_meals` populated, else the
  earliest-created; **then repoint every `EventGroceryItem.merged_into_grocery_item_id`
  onto the keeper** (the M68 fix, `grocery.py:768-780`) so a later unmerge subtracts
  from the surviving row, not a tombstone. Do **NOT** collapse into "the lower
  recordName" — that picks an arbitrary survivor (possibly a user-added/event-only
  row), loses meal context, and strands the event-merge pointers (reintroducing the
  M68 double-count). Phase 4/5 must test collapse-then-unmerge.
- **Duplicate slot** (`(week_id, day_name, slot)`): a partially-synced two-meal
  swap can leave a transient duplicate (the old `DEFERRABLE` constraint prevented
  this). The resolver MUST detect and repair duplicate `(day,slot)` pairs (push
  the loser to an empty slot or tiebreak on `sort_order`/`recordName`), never keep
  two meals in one slot.
- **Sort-order collisions**: re-sort locally; reconcile duplicate `sort_order`
  after a merge (fractional reindex or full re-sort on `(meal_date, sort_order,
  recordName)`).
- **Dangling soft refs**: null a `recipe_id` / `base_ingredient_id` /
  `ingredient_variation_id` / `assigned_guest_id` / `merged_into_*` when its
  target is gone (client-enforced SET NULL).

---

## 6. Client-enforced invariants strategy

CloudKit has **no unique constraints, no CHECK, no FK cascade, no multi-record
transactions, no ORDER BY**. Every Postgres guarantee becomes either a client
invariant + resolver repair, or a CloudKit-native mechanism. Strategy by category:

### 6.1 Uniqueness → deterministic recordNames + query-before-create + resolver collapse

**recordName policy is irreversible — fix it per record type before Phase 0.** A
record's `recordName` can never change without delete+recreate, which breaks every
inbound `CKReference` and on-device match key. Bucket every record type into exactly
ONE policy: **(a) preserved legacy PK** (migrated graph records, so references
survive); **(b) deterministic key** (singletons/junctions that must collapse
concurrent creates — note this solves *uniqueness only*, not field merge: two
offline devices writing the same deterministic name with different values still LWW
one away); or **(c) random UUID + post-sync dedupe** (logical-key rows two offline
devices can each mint — `PreferenceSignal`, aliases). Never key on a **mutable**
value (`WeekMealIngredient`, §5.2). Produce the per-type table as a Phase 0
deliverable; it is the one decision impossible to walk back after data syncs.

- **`UNIQUE(household_id, week_start)`** → query the zone for an existing Week
  before create; resolver collapses concurrent duplicates into the lower
  `recordName` (§5.3).
- **`DEFERRABLE UNIQUE(week_id, day_name, slot)` (slot swap)** → app-level
  invariant; swaps mutate both meals' `(day,slot)` in one `CKSyncEngine` batch, but
  **the batch is NOT atomic** — `CKSyncEngine` batches can partial-fail per record,
  and the `DEFERRABLE` commit-time guarantee has **no CloudKit equivalent**. So the
  resolver's duplicate-`(day,slot)` repair (§5.3) is the *only* safety net, not a
  nicety — a swap can transiently (or, on partial failure, durably until repair)
  leave two meals in one slot.
- **Composite/junction keys** → **synthesized deterministic recordNames** so
  concurrent creates collapse to one record instead of duplicating:
  `HouseholdSetting` = `"hsetting:<key>"`; `EventAttendee` = `"<eventID>_<guestID>"`;
  `EventPantrySupplement` = `"<eventID>_<stapleID>"`; `ProfileSetting` =
  the setting key; `DietaryGoal` = a fixed singleton recordName; `RecipeImage` =
  derived from `recipe_id` (enforces 1:1 — two writes target one record,
  generated_at tie-break dedups on read). Treat re-adding an existing pairing as
  **upsert, not insert**.
- **Per-user dedupe** (`PreferenceSignal` `(signal_type, normalized_name)`,
  `IngredientPreference` `(base, rank)`, `HouseholdTermAlias` `(term)`) → upsert by
  querying the zone for the logical key before insert (mirror server
  `upsert_*`); run a **merge-on-conflict dedupe after sync**, not just on local
  upsert (two offline devices can each mint a "new" record CloudKit can't reject).

### 6.2 Ranked ordering → store the column, sort locally, reconcile on merge

`sort_order` (+ `meal_date`), `rank`, `created_at` ordering, nested-step
`(parent_step_id, sort_order, id)` ordering, memory newest-first — all advisory in
CloudKit. The client persists the field, sorts in-memory on read, and reconciles
duplicate/gapped values after a merge (fractional indices or full re-sort with a
deterministic `recordName` tiebreak). `IngredientPreference` "lowest-rank =
primary" is computed client-side on the fetched set.

### 6.3 FK-pointer integrity → parent CKReference cascade + client SET-NULL

- **CASCADE edges** → parent `CKReference` with `action = .deleteSelf` so deleting
  the parent sweeps children: Recipe→{RecipeIngredient, RecipeStep, RecipeImage,
  RecipeMemory}, RecipeStep→substep, Week→subtree, Event→{attendees, meals,
  grocery, supplements}, EventMeal→inline ingredients, AssistantThread→messages,
  NutritionItem→match. The engine still must **enqueue** the deletes (orphan
  sweeping on merge is the client's job).
- **SET-NULL soft edges** → plain (non-parent) CKReferences or string keys the
  client nulls when the target is gone: `recipe_id`, `base_recipe_id`,
  `base_ingredient_id`, `ingredient_variation_id`, `recipe_template_id`,
  `assigned_guest_id`, `EventAttendee→Guest`, `FeedbackEntry.meal_id/grocery_item_id`,
  `EventGroceryItem.merged_into_*`, `Event.linked_week_id`,
  `AssistantThread.linked_week_id`, `AssistantMessage.attached_recipe_id`.
- **Catalog keys are plain Strings, not CKReferences** — they may point into
  PUBLIC (cross-database, where CKReferences are illegal) or the household zone; a
  dangling key just renders `resolution_status='unresolved'` / template fallback.
- **Self-ref subtlety**: `base_recipe_id` is SET-NULL (null `baseRecipeRef`,
  collapse the variant by flattening `override_payload_json` against the last-known
  base) while `parent_step_id`/`recipe_id` are CASCADE (`.deleteSelf`). Getting the
  CKReference action wrong (e.g. `.deleteSelf` on `baseRecipeRef`) would delete
  variants when a base is removed — two distinct deletion behaviors on
  self-referential edges.
- **`merged_into_id` catalog chains** → CKReference-by-recordName the client must
  WALK and TERMINATE: follow until `merged_into==nil`, guard cycles (cap depth),
  and on a dangling/uncached target (a household row merged into a now-PUBLIC
  approved row points shared→public) re-fetch or fall back to the source row.

### 6.4 Validation → client-side write guards

Enum-ish/CHECK constraints (`difficulty_score` 1–5, `choice_mode`, `goal_type`,
`signal_type`, `meal_type`/`source`) and the ~5 MB image upload guards
(`validate_upload_image`, base64 cap) move to client-side validation before write
(CloudKit enforces none). Image bytes go straight to a `CKAsset` file (the
base64-over-JSON transport is dropped).

---

## 7. iOS-26 AI tiering

### 7.1 The abstraction seam

One provider-agnostic AI call site (mirrors today's single `services/ai.py`
seam), with pluggable providers selected per-feature and per-tier:

```
AIProvider (protocol)
├── OnDeviceProvider      — Foundation Models framework
│     iOS 26: first-gen ~3B on-device model (guided generation @Generable)
│     iOS 27 GA: AFM 3 20B on-device · Private Cloud Compute (free tier)
├── BYOKeyProvider        — user's own key in the device Keychain (NEVER CloudKit)
│     → {OpenAI, Anthropic, Gemini, OpenRouter→FOSS}
└── CreditsGatewayProvider — optional SP-E server, our key, credit ledger
```

Provider keys live in the **device Keychain**, never synced to CloudKit
(`ai_openai_api_key` / `ai_anthropic_api_key` / legacy `ai_direct_api_key`
`ProfileSetting` rows are dropped at migration; `ProfileResponse.secret_flags` is
dropped). No server usage counter gates calls — on-device is free; BYO-key/credits
rate-limiting (if any) is designed into the credits gateway (SP-E), not inherited
from the removed `UsageCounter`.

### 7.2 Feature → tier routing (SP-B refines; SP-A only fixes the seam)

| Feature | iOS 26 default | iOS 27 GA |
|---|---|---|
| **Light tasks** (substitution, pairing, difficulty score, seasonal, normalization, `split_summary_into_steps`/`summarize_steps`, companion drafts) | **on-device** (first-gen) | on-device (AFM 3) |
| **Week-gen** (21-meal structured plan — the hard reasoning task) | **cloud** (BYO-key/credits) by default; on-device experimental — Spike 2's A/B gates the on-device default | on-device AFM 3 / PCC **if** Spike 2 at GA clears it (hard gate: zero allergy violations), else stays cloud |
| **Recipe image generation** | cloud (BYO-key/credits) — no on-device image model; `ImageGenUsage` telemetry dropped | unchanged |
| **Assistant chat / planning turns** | on-device for light turns; cloud for tool-heavy planning | on-device AFM 3 broadens coverage |

SP-A's only obligation is to **build the seam** (the protocol + provider
selection + Keychain key store) so SP-B can wire real backends without touching
the data plane. The derivation logic that was server-side (`effective_recipe_data`,
`split_summary_into_steps`, `normalize_name`) moves on-device regardless of AI
tier — it already runs on read.

---

## 8. Public catalog

### 8.1 The client cannot write public; a curator must

CloudKit PUBLIC-db writes from arbitrary users would let any user corrupt the
global catalog, and the app dropped server auth. So **no client write path to
PUBLIC exists.** The public catalog is owned by a single **curator identity** —
the same optional small server envisioned for the credits gateway (SP-E) — running
the existing USDA / Open Food Facts ingest + `product_rewrite` normalization +
governance promotion, writing PUBLIC records under one trusted CloudKit account.

- **Seed** (one-time, out-of-band — NOT a user migration): the curator bulk-loads
  all approved `BaseIngredient` (household_id NULL) + global `IngredientVariation`
  + `NutritionItem` + `IngredientNutritionMatch` + built-in `RecipeTemplate` +
  `ManagedListItem` into PUBLIC. Curator-enforced-at-publish invariants replace the
  Postgres unique indexes (dedupe `normalized_name` / `(kind, normalized_name)` /
  `slug` before publishing); clients dedupe defensively on read.
- **Submission flow** (only if/when the curation server is built): a household
  "submits" by writing a `submission_status='submitted'` row to its OWN shared
  zone (the M63 rule: a household resolution must NOT auto-promote unknowns into
  everyone's catalog). The curator reads opted-in submissions out-of-band and
  republishes approved rows to PUBLIC (the old `approve_submission`'s "clear
  household_id, join global" becomes "curator copies the row into PUBLIC; the
  household keeps or tombstones its shared copy"). Without that server, PUBLIC is a
  **frozen one-time seed** and `submitted`/`rejected` are inert local flags.

### 8.2 Resolving against a catalog the client doesn't fully hold

`resolve_ingredient`'s control flow assumes the whole catalog is queryable in one
DB session; on-device, PUBLIC is only **partially cached**. The client resolves in
this order:

1. local PUBLIC cache (common head, prefetched) →
2. own household shared zone (household-tier rows) →
3. on cache-miss, a `CKQuery` against PUBLIC by `normalized_name` **before**
   minting a `household_only` row (so it doesn't fragment the catalog with private
   dups of canonical rows) →
4. offline / still-miss: mint a provisional `household_only` row, reconcile later.

Resolver visibility (`search_base_ingredients` "approved OR own-household") becomes
a client-side **UNION** of the PUBLIC cache + the household zone; other households'
rows are inaccessible by construction (zone isolation). A row promoted to PUBLIC
then later edited by its household creates two copies — the client prefers the
PUBLIC approved copy and tombstones/ignores the stale shared one. Design the
partial-cache + on-demand `CKQuery` to stay within PUBLIC-db rate limits (batched
prefetch of common ingredients; cache the long tail on resolve).

---

## 9. Phased build sequence

Each phase is independently shippable/testable, ordered by dependency and risk,
iOS-26-targeted. **Phases 0–9 are blocked on a CloudKit container provisioned under
the dev team**; a standalone container for SP-A is cleanest. The provisioning gate
escalates: Phase 0 needs the container; **Phase 0.5 and Phase 2 need the harder gate
— the Production CloudKit schema deployed + two real Apple IDs + TestFlight** (cross-
Apple-ID `CKShare` testing typically can't run in the Dev environment), and the
Production schema must be **frozen** before any real user data syncs (CloudKit
schema is additive-only). Phase 6 is additionally coupled to **SP-E curator infra**
(the PUBLIC catalog can't be seeded without it).

### Phase 0 — Container + schema + provisioning  ⟵ needs the dev-team container
- Provision the CloudKit container under the dev team; define record types,
  fields, indexes (queryable fields), and the PRIVATE/SHARED/PUBLIC database
  schema in the CloudKit dashboard.
- Stand up the custom-zone + `CKShare` scaffolding (create zone, root
  `HouseholdProfile`, share).
- **Verify**: a test build creates a household zone, writes/reads
  `HouseholdProfile` round-trip in dev environment; schema deploys to the CloudKit
  dashboard with no validation errors. Deliverable: the **per-record-type recordName
  policy table** (§6.1) and the **queryable-fields list** (both irreversible).

### Phase 0.5 — Coexistence + shared-zone spike (validate the §4.2 keystone)  ⟵ container + two Apple IDs
- **Throwaway, but it gates the architecture.** Prove the single most load-bearing,
  least-validated assumption BEFORE Phases 2–7 build on it:
  (a) `NSPersistentCloudKitContainer` (per-user private zone) + `CKSyncEngine`
  (custom household zone) **coexisting in ONE container** without change-token /
  `CKDatabaseSubscription` contention; and (b) `CKSyncEngine` driving a `CKShare`d
  zone from the **participant** side — a second Apple ID accepts the share and
  reads/writes through the engine. Spike 1 explicitly did NOT cover CKShare
  participant or zone-token semantics.
- **Verify**: two Apple IDs share one custom zone; the participant's `CKSyncEngine`
  syncs writes both directions; the private NSPCKC stack and the household
  CKSyncEngine run in one app with no interference. **If this fails, §4.2 and the
  sharing model change here — cheaply — instead of being discovered in Phase 4.**

### Phase 1 — Per-user PRIVATE plane (`NSPersistentCloudKitContainer`)  ⟵ container
- Lowest-risk, no sharing, no sticky merge: `ProfileSetting`, `DietaryGoal`,
  `PreferenceSignal`, `IngredientPreference`, `AssistantThread`+`AssistantMessage`
  in the PRIVATE db via `NSPersistentCloudKitContainer`. Build the per-user
  invariant enforcement (singleton/keyed recordNames, upsert dedupe, client
  validation).
- **Verify**: profile/prefs/transcript create-edit-delete round-trip across two
  devices on one iCloud account; dedupe holds; assistant transcript ordering
  preserved.

### Phase 2 — Household zone + `CKShare` sharing + plain-CRUD content
- Create the household zone day-one-shared; `UICloudSharingController` invite +
  accept; owner/participant model; single-household-per-user enforcement; decide
  ownership-transfer policy (pin-to-owner vs re-host).
- Land the plain-CRUD household records on the household `CKSyncEngine` as
  LWW pass-through: `HouseholdProfile`, `HouseholdSetting`, `HouseholdTermAlias`,
  `Recipe`+`RecipeIngredient`+`RecipeStep`, `Guest`, `EventMeal`+`EventMealIngredient`,
  `EventAttendee`, `WeekChangeBatch`+`Event`, `FeedbackEntry`, household-tier
  `BaseIngredient`/`IngredientVariation`. Wire `.deleteSelf` cascades, SET-NULL
  cleanup, sort/dedupe.
- **Land the `WeekChangeBatch`/`WeekChangeEvent` retention/prune policy WITH this
  phase** (not "future work"): append-only audit now syncs to every member's iCloud
  quota the moment it lands — either keep it local-only or prune on a cap/age here.
- **Verify**: two iCloud accounts share one household; both see/edit recipes,
  guests, aliases; a recipe delete cascades its children; member writes succeed
  (not read-only).

### Phase 3 — `CKAsset` imagery
- `RecipeImage` (required asset, 1:1 via recipe-derived recordName) and
  `RecipeMemory` (optional asset) as `CKAsset` file-refs; client-side
  size/MIME validation; UI tolerates a synced record whose asset hasn't downloaded
  (placeholder, not broken image); `.deleteSelf` cascade frees assets on recipe
  delete.
- **Verify**: image generate/upload/delete round-trips across two devices; 1:1
  invariant holds under concurrent regenerate; recipe delete leaves no orphan
  asset.

### Phase 4 — The field-merge resolver + sticky grocery (HIGHEST RISK)  ⟵ Spike 1 core
- Port `regenerate_grocery_for_week` / `_apply_fresh_to_existing` / `_key_for_*` /
  `normalize_name` **verbatim** to Swift; implement the §5 per-field resolver on
  the household `CKSyncEngine`; land `Week`+subtree+`GroceryItem` sticky merge;
  slot-swap atomic batch + duplicate repair; duplicate-week collapse.
- **Verify**: the **real two-device `CKSyncEngine` run** Spike 1 deferred — all 4
  Spike-1 failure modes (tombstone resurrection, `event_quantity` loss, override
  clobber, check-state convergence) pass on live CloudKit across two devices; the
  match-key produces no duplicate rows against migrated data.

### Phase 5 — Event↔week cross-aggregate merge
- Extend the §5 resolver to `Event`/`EventGroceryItem`/`EventPantrySupplement`:
  `manually_merged` pin stickiness, `merged_into_*` pointer replay,
  `event_quantity` writer-ownership across the event↔week boundary; port
  `merge_event_into_week` / `unmerge_event_from_week` / `apply_auto_merge_policy`.
- **Verify**: concurrent merge/unmerge across two devices does NOT reproduce the
  3→6→9 double-count; unmerge-to-zero self-deletes event-only rows; pin survives a
  concurrent unrelated `Event` edit.

### Phase 6 — PUBLIC catalog read path + resolver
- Curator seed tool (operator-run, out-of-band) loads PUBLIC; client read-cache +
  on-demand `CKQuery`-by-`normalized_name`; the §8.2 resolve order; UNION
  visibility; `merged_into` chain walk with cross-database fallback.
- **Verify**: client resolves a known catalog ingredient from cache, a long-tail
  one via `CKQuery`, and mints a `household_only` row only after a confirmed PUBLIC
  miss; no private dup of a canonical row.

### Phase 7 — Migration import + cutover
- One-time per-household / per-user import (§3): pull the signed export bundle over
  the surviving legacy endpoint, write records into the correct DB/zone with PKs
  preserved as recordNames, wire parent CKReferences, round-trip sticky fields and
  `merged_into_*` pointers verbatim; idempotent re-run; coexistence window.
- **Verify**: a migrated household's grocery list, event merges, recipe variants,
  and check-state match the pre-migration Postgres state byte-for-byte on the
  sticky fields; re-running the import creates no duplicates.

### Phase 8 — AI seam + on-device platform handoff (SP-A's slice)
- Build the §7 `AIProvider` abstraction + Keychain key store + provider selection
  (real backends are SP-B); confirm no data-plane code path still consults a
  dropped `Subscription`/`UsageCounter`/server-push record.
- **Verify**: a light AI task (e.g. substitution) routes through the on-device
  provider; a week-gen routes through the cloud provider; no dropped-table code
  path is reachable.

### Phase 9 — Migration cutover close (own the completeness signal)
- Stand up the migration-status ledger (§3.3): the export endpoint records, per
  household, "delivered + receipt-confirmed"; expose an operator view of remaining
  un-migrated households + an explicit dormant-user policy (indefinite hold vs
  comms-then-sunset). This phase OWNS the seam SP-D depends on — it produces the
  *signal* that retiring the server is safe; it does not retire it (that's SP-D).
- **Verify**: the ledger reports 100% of active households migrated (or an explicit
  accepted-residual list) — SP-D gets a green light, not a guess. Closes the
  coexistence window the plan otherwise leaves dangling.

### Cross-phase notes
- **Container provisioning gates Phases 0–9** (every CloudKit operation needs it);
  Phase 0.5 validates the §4.2 keystone and Phase 4 completes Spike 1's deferred
  real-device confirmation.
- **Retention**: the `WeekChangeBatch`/`WeekChangeEvent` prune lands **in Phase 2**
  (above), not as future work — append-only audit on a synced zone is a quota
  regression the instant it ships. Archived `AssistantThread`s (soft-archive still
  syncs) need the same client purge path; fold into Phase 1.
- **SP-D** (server retirement, Fly off, Postgres decommission, MCP/OAuth/SSO
  removal) runs AFTER Phase 9's migration-status ledger confirms all households
  migrated — never on assumption.

---

## 10. Top risks (carry into the plan)

1. **The grocery field-merge resolver** (Phase 4) is the make-or-break component —
   a naive resolver silently corrupts shopping lists. Mitigate with verbatim
   server-logic port + the real two-device test + match-key tests on migrated data.
2. **Match-key drift** — any divergence between on-device and legacy server key
   logic duplicates rows. Port verbatim, test against migrated data.
3. **One-zone / one-stack** — modeling any household group in a second zone splits
   the household; running two physical stacks on one zone races the change token.
   Enforce single-`CKSyncEngine`-per-household-zone (§4.2).
4. **Slot-swap atomicity** — no CloudKit transaction; the resolver must repair
   transient duplicate `(day,slot)` deterministically.
5. **Ownership transfer** has no CloudKit primitive — decide pin-to-owner vs
   re-host in Phase 2.
6. **Single-household-per-user** is no longer DB-enforced — strict client
   enforcement on share-accept, or shared content from two households intermingles.
7. **Cross-database soft refs** (private→shared, shared→public) dangle on
   access-loss / catalog merge — render "unavailable," never crash.
8. **Migration sticky-field fidelity** — `merged_into_*` and `event_quantity` MUST
   import intact or the first on-device merge double-counts.
9. **PUBLIC-db rate/scale limits** — design the partial-cache + on-demand query to
   stay within them for the large USDA/OFF catalog.
10. **Multi-member migration identity match** — unmatched members must re-accept a
    share URL out-of-band; some households may fragment.

---

## 11. Adversarial-review resolutions (2026-06-15)

The blueprint was adversarially reviewed against the codebase (match key, dedupe
keeper, SET-NULL vs CASCADE self-refs, the DEFERRABLE slot constraint, sticky
fields — all verified accurate). The exposure was concentrated in a few
hard-to-reverse decisions, now folded in:

| # | Finding | Resolution |
|---|---|---|
| **D1** | Grocery dedupe "collapse into lower recordName" reinvented the keeper policy, dropping the M68 `EventGroceryItem` repointing → event double-count on unmerge | §5.3: port the **semantic** keeper (`grocery.py:794-805`) + repoint `merged_into_grocery_item_id` verbatim; Phase 4/5 add a collapse-then-unmerge test |
| **A1** | recordName policy ambiguous **and irreversible**; `WeekMealIngredient` mutable content-hash-as-recordName is incoherent | §6.1: per-type recordName-policy bucket (legacy-PK / deterministic / random+dedupe) as a Phase 0 deliverable; §5.2: stable id as recordName, content-hash becomes a queryable `matchKey` field |
| **B1/E2** | "one `CKSyncEngine` on the shared zone" + NSPCKC coexistence is unproven yet load-bearing from Phase 2 | new **Phase 0.5 spike** validates CKShare-participant + dual-stack coexistence before Phases 2-7 depend on it |
| **C1** | owner's two devices race zone creation → forked household | §2.2: deterministic discover-then-claim (query for an owned zone + deterministic zone name) |
| **C2/C3** | migration had no resume sentinel / completeness signal | §3.3: `MigrationReceipt` sentinel + server migration-status ledger; new **Phase 9** owns the cutover-close signal SP-D needs |
| **D2** | match-key prose dropped the `resolution_status=="locked"` guard | §5.2: guard restored explicitly |
| **C4** | check-state `(is_checked, checked_at, checked_by)` could tear under per-field LWW | §5.1: resolve the triple as a unit |
| **E1** | slot-swap framed as an "atomic batch" (false — CKSyncEngine batches partial-fail) | §6.1: batch is non-atomic; the resolver's duplicate-`(day,slot)` repair is the only safety net |
| **E3** | audit-record prune deferred to "future work" = instant quota regression | §9: the prune lands **with Phase 2** |

**Residual design calls for you (not blockers — decide as we build):**
1. **Ownership transfer** (§2.4) — pin hosting to the original owner (simple, recommended for v1) vs an expensive re-host-the-zone flow.
2. **Dormant-user sunset** (§3.3 / Phase 9) — indefinite coexistence hold vs a comms-then-sunset date for users who never launch the iOS-26 build.
3. **Public catalog** (§8) — is the curator (SP-E) server in scope soon, or does PUBLIC ship as a **frozen one-time seed** (submissions inert) until it exists?
