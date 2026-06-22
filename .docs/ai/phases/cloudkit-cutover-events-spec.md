# SP-C — CloudKit cutover, slice 4: Events

> Design spec. 2026-06-20. Fourth cutover slice. Reuses the skeleton; SP-A built the event types +
> the event↔week merge engine, so this is mostly wiring + one generation port.

## 0. Goal + scope
Cut the **Events** feature (parties/potlucks: events, menus, guests/attendees, and the event↔week
grocery merge) over to CloudKit.

**IN:** event create/fetch/update/delete; event meals add/update/delete; guests (roster CRUD) +
attendees; the **event↔week grocery merge/unmerge** (wire SP-A's built engine); event-grocery
generation from event meals; migration of events+guests; un-gate the Events tab.
**OUT (→ AI track, coming-soon):** `generateEventMenu` (AI menu design), `generateEventMealRecipe`
(AI recipe draft — also a direct-apiClient leak to close).
**DEFER:** `EventPantrySupplement` (M28) — depends on the Pantry plane (slice 5); hide its UI here.

## 1. What SP-A already built (wire, don't rebuild)
- **Manifest types (complete, Phase 2b):** `.guest` (roster), `.event` (root; fields name/eventDate/
  occasion/attendeeCount/notes/status/autoMergeGrocery/manuallyMerged/timestamps; ref `linkedWeekID`
  crossDBString→Week), `.eventAttendee` (det-keyed `<eventID>_<guestID>`; refs event cascadeParent +
  guest setNull), `.eventMeal` (refs event cascadeParent + recipe setNull + assignedGuest setNull),
  `.eventMealIngredient` (refs eventMeal cascadeParent + base/variation crossDB). **No new manifest types.**
- **Event↔week merge engine (Phase 5, pure):** `EventMergeEngine.mergeEventIntoWeek` /
  `unmergeEventFromWeek` (HARD-delete event-only week rows, not tombstone) / `resolveTargetWeek`
  (linkedWeekID else eventDate-covering week) / `applyAutoMergePolicy` (autoMergeGrocery +
  manuallyMerged-pin lifecycle). `EventMergeAdapter` bridges it to the engine. `EventGroceryCodec`
  (EventGroceryItem CKRecord). `EventSyncMerger` (manuallyMerged sticky-OR). The session's
  DispatchingMerger already holds [Grocery, EventGrocery, Event].
- **Migrate transforms:** `migrateEvent` / `migrateEventGroceryItem` (+ the manifest-driven
  migrate for guest/eventMeal/etc.).
- **The just-built Week/Grocery slice** (WeekRepository, GroceryRepository, GroceryGenerator,
  WeekRecordMapper, WeekMigrationLoader) — the pattern to mirror exactly.

## 2. Components to build
| Component | New? | Responsibility |
|---|---|---|
| `EventRecordMapper` | new (SimmerSmithKit/CloudKit) | `Event ⇄ .event (+ .eventMeal + .eventMealIngredient + .eventAttendee children)`; `Guest ⇄ .guest`. Mirror WeekRecordMapper. |
| event-grocery generation | new/generalize | event meals → `EventGroceryItem` set (port `refresh_event_grocery` from the server, OR generalize `GroceryGenerator`'s aggregation core to emit EventGroceryItem). Needed so the merge has data + refreshes on meal change. Reuse `GroceryNormalize`. |
| `EventRepository` | new (app Data/) | event/meal/attendee CRUD over the store (reassemble Event aggregate); the **merge/unmerge** via `EventMergeAdapter`; event-grocery refresh via the generator. Reactive on storeRevision. |
| `GuestRepository` | new (app Data/) | guest roster CRUD (`.guest`) — small; or fold into EventRepository. |
| `AppState+Events` rewire | modify | DATA methods → repositories (signatures preserved); AI methods (`generateEventMenu`, `generateEventMealRecipe`) → coming-soon/guarded + close the `apiClient.generateEventMealRecipe` leak. |
| un-gate Events tab | modify MainTabView | render EventsView (CloudKit-backed) instead of ComingSoonView. |
| `EventMigrationLoader` | new (app Data/) | one-time Fly pull of events+guests+event-grocery → CloudKit (mirror WeekMigrationLoader; receipt `migrated:events`; one-shot Fly auth, reusing the import trigger). |
| schema completion+deploy | cktool | the `.event`/`.eventMeal`/`.eventMealIngredient`/`.eventAttendee`/`.guest` + `EventGroceryItem` prod schemas are auto-created→field-incomplete (like recipes/weeks); complete + deploy. NO new types this slice. |

## 3. The event↔week merge (wire, the #2 risk)
The merge lifecycle is built (`EventMergeAdapter`/`EventMergeEngine`). The slice WIRES it:
- `mergeEventGroceryIntoWeek(eventID, weekID)` → `EventMergeAdapter` merge into the week's GroceryItems
  (sets `linkedWeekID`, marks event rows `mergedIntoWeekID`/`mergedIntoGroceryItemID`, bumps matched
  week rows' `eventQuantity`). The GroceryRepository's week rows already field-merge.
- `unmergeEventGroceryFromWeek` → the adapter's unmerge (HARD-deletes event-only week rows; clears links).
- `toggleEventAutoMerge` + `applyAutoMergePolicy` on event/meal/date changes (re-resolve target week).
- **Invariant:** unmerge HARD-deletes event-only week rows but PRESERVES week rows with user investment
  (overrides/checks/user-added) — the engine already does this; the wiring must not bypass it.

## 4. Event aggregate + generation
- **Read:** reassemble Event from the `.event` record + `.eventMeal` children (+ their
  `.eventMealIngredient`) + `.eventAttendee` children (+ resolve the `.guest`). `EventSummary` derived.
- **Write:** decompose Event → records (child-diff like WeekRepository). Attendees det-keyed.
- **Event-grocery generation (`refreshEventGrocery`):** aggregate the event meals' ingredients →
  EventGroceryItem set (the analog of the week regen). **Read the server authority** (`app/services/`
  event-grocery refresh) and match it; reuse `GroceryNormalize`. Preserve any sticky event-grocery
  state. This is the one real algorithm port — TDD it headlessly.

## 5. AppState rewire
- DATA (refreshEvents, fetchEvent, create/update/delete Event, add/update/delete EventMeal,
  refreshEventGrocery, merge/unmerge, toggleEventAutoMerge, refreshGuests, upsertGuest) → repositories.
- AI (`generateEventMenu`, `generateEventMealRecipe`) → guarded/coming-soon + `// AI TRACK`. Close the
  `EventMealEditorSheet → apiClient.generateEventMealRecipe` direct leak (route through AppState, then
  guard it). Grep Events views for other direct apiClient calls.
- EventPantrySupplement methods → leave dormant (DEFER); hide the supplement UI section in the build.

## 6. Verification
- **Headless:** `EventRecordMapper` round-trip (event + meals + ingredients + an attendee + guest);
  the event-grocery generation fidelity tests; any new manifest test (none expected — types exist).
- **On-device (TestFlight):** (1) migrate events+guests in; (2) Events tab: create/edit/delete an
  event + meals + guests persist + sync; (3) **merge an event into a week → its groceries appear on the
  week's list (eventQuantity); unmerge → they're removed but a user-checked/overridden week row survives**;
  (4) auto-merge policy on date change re-targets; (5) Recipes/Weeks still fine.

## 7. Risks
- **Merge/unmerge correctness** — wire the built engine faithfully; don't bypass the user-investment
  preservation on unmerge (the part that, done wrong, deletes a user's checked grocery row).
- **Event-grocery generation fidelity** — match the server; TDD it.
- **Schema field-incompleteness** — complete+deploy the event/guest/EventGroceryItem types (controller
  preps cktool; one-click deploy). No new types → lower-risk than weeks (which added WeekMealSide).
- **The merge touches the WEEK's GroceryItems** — depends on slice 3 (Weeks+Grocery) being in place
  (it is, on this branch). The week field-merge handles concurrent peers.
