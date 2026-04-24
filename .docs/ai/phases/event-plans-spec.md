# M10: Event Plans — Spec

## Context

SimmerSmith today handles two planning surfaces well: the recurring
week and individual recipes. But real households also plan **events** —
Easter dinner, a birthday party, a Friendsgiving — where the meal is a
one-off, the guest list is specific, and the constraints (allergies,
dietary preferences, kids vs. adults) are much more varied than a
typical week's household-wide dietary goal.

Target user flow:

> "Planning Easter for 12. Aunt Sue is gluten-free, my nephew won't eat
> anything green. I want a traditional ham dinner but with one obvious
> GF option and one kid-friendly plate. Help me nail the menu and
> quantities, and add the groceries to this week's list so I'm making
> one Instacart run."

The interesting design problems are:

1. **Mixed-constraint menu generation**: the AI needs to propose a
   menu that works for the majority while giving constrained guests
   something *actually good*, not just "the salad". Hard-avoids
   should block no more than 1-2 dishes, not the whole menu.
2. **Headcount-aware quantities**: recipes scale by servings, but
   party quantities (esp. proteins + sides) have real rules of thumb
   that differ from weekly meals.
3. **Grocery bridging**: event groceries live separately (so the user
   can see what's for the party) but should be *mergeable* into the
   current week's grocery list so shopping is one trip. If the week
   has 1 lb chicken and the event has 5 lb, the merged list shows
   6 lb chicken as one line (attributed to both).

## Scope

**Decided via AskUserQuestion (2026-04-24):**
- New top-level **Events tab** (first-class, alongside Week / Recipes
  / Assistant).
- **Structured reusable guest list**: named guests with saved
  allergies/preferences, reusable across events.

**In-scope for this milestone:**
- CRUD for events + guests
- AI menu generation for an event (multi-dish, mixed constraints)
- Event grocery list (separate, auto-generated from event meals)
- Merge-into-this-week action on event grocery items
- iOS Events tab with list + detail views

**Explicitly out-of-scope (follow-up phases after MVP):**
- Instacart / external checkout
- Event templates (Thanksgiving, birthday, etc.) — come later once
  we have real usage data
- Calendar sync / invitations
- Per-guest portion tracking ("Sue gets 6 oz of the GF dish")

## Critical files (to mirror)

**Backend patterns to copy:**
- `app/models/week.py` — Week + WeekMeal relationship
  → `app/models/event.py` (new) with Event + EventMeal
- `app/models/catalog.py:172` — IngredientPreference shape to model
  Guest dietary constraints
- `app/services/grocery.py:124` — `build_grocery_rows_for_week`
  base-ingredient aggregation → mirror as
  `build_grocery_rows_for_event` and eventually
  `merge_event_into_week`
- `app/services/week_planner.py:514` — `generate_week_plan`
  prompt/parse shape → adapt as `generate_event_menu`
- `alembic/versions/20260419_0017_assistant_planning_tools.py` —
  migration scaffold

**iOS patterns to copy:**
- `SimmerSmith/.../App/AppState.swift:10-16` — MainTab enum, add
  `.events`
- `SimmerSmith/.../Features/Week/WeekView.swift` — list + detail
  structure
- `SimmerSmith/.../Features/Recipes/RecipeDetailView.swift` —
  sectioned detail with sheet mounting

## Data model

```
Guest
  id, user_id, name, relationship (str, optional),
  dietary_notes (text), allergies (text),
  active (bool), created_at, updated_at

Event
  id, user_id, name, event_date (date, optional),
  occasion (str — "holiday" / "birthday" / "dinner party" / "other"),
  attendee_count (int),
  notes (text),
  status ("draft" / "confirmed" / "complete"),
  linked_week_id (nullable FK — used when grocery is merged into a week),
  created_at, updated_at

EventAttendee  (M2M join)
  event_id (FK Event), guest_id (FK Guest),
  plus_ones (int, default 0)
  — optional: for MVP we let a single Guest count for N people via plus_ones

EventMeal
  id, event_id, role ("main" / "side" / "starter" / "dessert" /
                       "beverage" / "other"),
  recipe_id (FK Recipe, optional — nullable for AI-generated inline),
  recipe_name (str), servings (float),
  scale_multiplier (float, default 1.0),
  notes (text), sort_order (int),
  ai_generated (bool), approved (bool),
  created_at, updated_at

EventMealIngredient
  id, event_meal_id, base_ingredient_id (optional),
  ingredient_variation_id (optional),
  ingredient_name, normalized_name, quantity (float), unit,
  prep, category, notes

EventGroceryItem
  id, event_id, base_ingredient_id (optional),
  ingredient_variation_id (optional),
  ingredient_name, normalized_name, category,
  total_quantity (float), unit, quantity_text,
  from_meals (json — list of event_meal_ids),
  merged_into_week_id (optional FK — set when user merges to weekly list),
  merged_into_grocery_item_id (optional FK),
  created_at, updated_at
```

Key reuse: `EventMealIngredient` structurally mirrors
`WeekMealIngredient`, so `build_grocery_rows_for_event` can share most
of the aggregation logic with `build_grocery_rows_for_week` by
abstracting the input iterator.

## Phases

Each phase is independently shippable. Ship in order.

---

### Phase 1 — Backend data model + CRUD (~3 hrs)

- Alembic migration creating all 5 new tables.
- ORM models in `app/models/event.py` + export from
  `app/models/__init__.py`.
- Pydantic schemas in `app/schemas/event.py`.
- Service layer `app/services/events.py` — `create_event`,
  `get_event`, `list_events`, `update_event`, `add_attendee`,
  `remove_attendee`, `upsert_event_meal`, `delete_event_meal`.
- Guest CRUD in `app/services/guests.py` — mirrors
  `ingredient_preferences`.
- REST endpoints under `/api/events` and `/api/guests`.
- Tests covering CRUD + ownership isolation (critical given
  multi-user data isolation test coverage already in place).

No AI, no iOS yet. The phase proves the data shape.

---

### Phase 2 — AI event menu generation (~3 hrs)

- New `app/services/event_ai.py` with `generate_event_menu(event,
  guests, settings, ...)`.
- Prompt design:
  - Header: occasion, date, attendee_count, host preferences,
    dietary goal (if set).
  - Attendee block: each guest's name, allergies, dietary notes.
    AI is instructed to design the core menu for the majority, then
    ensure at least one dish per meal role is compatible with each
    constraint (or clearly call out when it can't be done without
    rewriting the whole menu).
  - Quantity hint: standard party portions per role (e.g. 6-8 oz
    protein/person, 2 sides at 4 oz each).
  - Output schema: list of menu items with role, recipe draft,
    servings scaled to attendee_count, and a `constraint_coverage`
    field describing which guests it works for.
- Strict-JSON parse via pydantic.
- POST `/api/events/{id}/ai/menu` — triggers generation, persists
  as EventMeals, returns the list.
- Tests with monkeypatched provider (happy path + "Sue is GF" ends
  up with a dedicated GF dish).

---

### Phase 3 — Event grocery list + weekly merge (~2 hrs)

- Refactor `build_grocery_rows_for_week` in `app/services/grocery.py`
  to take an ingredient-source iterator so it can also drive event
  grocery rows without copy-paste.
- New `build_grocery_rows_for_event(session, event_id)` returning
  `EventGroceryItem` rows.
- New `merge_event_into_week(session, event_id, week_id)` that:
  - Aggregates event rows by the same base_ingredient key used
    weekly.
  - For each match, finds the current week's matching `GroceryItem`
    and adds the event's `total_quantity` to it (preserving original
    week quantity separately in a new `event_contribution` json
    field, OR simplest MVP: just add and record `merged_from_event_id`
    on the GroceryItem for traceability).
  - Marks the `EventGroceryItem.merged_into_week_id`.
- POST `/api/events/{id}/grocery/refresh` — regenerates event grocery.
- POST `/api/events/{id}/grocery/merge?week_id=...` — merges.
- Tests including the quantity-combining case.

---

### Phase 4 — iOS: Events tab + create flow (~3 hrs)

- Add `.events` to `MainTab` enum (AppState.swift).
- New `SimmerSmith/.../Features/Events/` directory:
  - `EventsView.swift` — list view (empty state, upcoming / past)
  - `EventDetailView.swift` — name + date + attendee chips +
    "Generate menu" button + menu meal cards + grocery section
  - `EventCreateSheet.swift` — name, date picker, attendee count,
    guest picker (reuse existing attendees or add new inline),
    occasion picker, free-text notes
  - `GuestPickerView.swift` — reusable from guest CRUD endpoint
- `AppState+Events.swift` — refresh events, create event, generate
  menu, refresh grocery, merge into week.
- `SimmerSmithAPIClient` methods for every new endpoint.
- `SimmerSmithKit` models for Event, Guest, EventMeal,
  EventGroceryItem.
- Nav icon + label ("Events", `party.popper`).

---

### Phase 5 — Guest CRUD iOS (~1.5 hrs)

- `Settings → Guests` section (mirrors the existing Ingredient
  Preferences section).
- Guest editor sheet: name, relationship, allergies (chip picker
  sourced from the ingredient catalog, same as the wand menu uses),
  dietary notes (free text), active toggle.
- Reuse `GuestPickerView` from Phase 4 inside `EventCreateSheet`.

---

### Phase 6 — Merge into weekly groceries (iOS) (~1.5 hrs)

- In `EventDetailView`, grocery section gets a "Merge with this week"
  button when a week exists for the event's date.
- After merge, event grocery rows show a `Merged` chip with a link
  to the week's grocery list.
- Undo = DELETE `/api/events/{id}/grocery/merge?week_id=...`.

---

## Verification

**Per-phase tests** listed above. Full backend suite + iOS build must
stay green at every commit.

**End-to-end smoke** (after Phase 6):
1. Settings → Guests → add "Aunt Sue (gluten-free)" and "Nephew Leo
   (no mushrooms, no greens)".
2. Events tab → New Event → "Easter Dinner" → date set, attendees = 12,
   pick Sue + Leo from guest list.
3. Generate menu → observe a traditional ham + sides menu; at least
   one side is GF; Leo has a safe plate.
4. Grocery tab on event → see 20+ items with aggregated quantities.
5. Merge into this week → open Week → grocery shows combined totals
   with event attribution on touched lines.

**Sequencing**: phases 1-4 are the shippable MVP (Events tab exists,
menus generate, groceries list). Phases 5-6 round it out. Phase 7+
(Instacart, templates, etc.) are post-launch.
