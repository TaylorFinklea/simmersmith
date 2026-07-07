# SimmerSmith Privacy Policy — REWRITTEN DRAFT (bead simmersmith-5w8)

> Draft status: senior-tier content rewrite grounded in the current codebase (2026-07-07).
> Not yet published. When approved, port this content into `docs/privacy/index.html`
> (hosting/URL change is tracked separately as bead 990.11 — "re-host off simmersmith.fly.dev
> FIRST"). Replace `[DATE]` with the actual publish date before shipping.
>
> This draft describes the app **as the code currently behaves**, verified by reading source
> (not assumed from the architecture pivot). See the companion file
> `privacy-policy-asc-label-notes.md` for the App Store Connect nutrition-label mapping, and
> the "Open questions for the human reviewer" section at the bottom of this file for a few
> things that need a product decision before this ships.

---

## SimmerSmith Privacy Policy

**Summary.** SimmerSmith is a meal-planning app built entirely on Apple's iCloud. There is no
SimmerSmith account system and no SimmerSmith server that stores your data — your household's
recipes, meal plans, and grocery lists live in **your own iCloud account** (and, if you share a
household, in an iCloud data zone shared with the people you invite). SimmerSmith's AI features
work by sending relevant data **directly from your iPhone** to an AI provider **you choose and
pay for with your own API key** — OpenAI, Anthropic, or OpenRouter for meal planning and the
assistant, and OpenAI or Google Gemini for recipe images. We (the developer) never see your
data — it never passes through a server we operate.

### 1. What SimmerSmith stores, and where

- **Your iCloud account is your identity.** There is no username/password sign-up. The app
  determines who you are from the Apple ID you're signed into on your device, via Apple's
  CloudKit framework. If you're not signed into iCloud, the app can't set up your household.
- **Household data lives in a private CloudKit "household" zone in your iCloud account**:
  recipes and their ingredients/steps, meal plans ("weeks"), grocery lists, pantry staples,
  events and the guests you've added to them (including any allergies or dietary notes you
  record for a guest), household settings, and custom terminology you've taught the app.
  AI-generated recipe images are also stored there as iCloud file attachments.
- **Some data is private to you alone**, even within a shared household: your personal dietary
  goals (calorie/macro targets), your personal ingredient preferences and allergy flags, and
  your conversation history with the in-app AI assistant. This data syncs across your own
  devices via your private iCloud database, but is never visible to anyone you share a
  household with.
- **A small amount of data stays on-device only** and is not synced anywhere: your BYO AI
  provider API key(s) (see §4), which Reminders list you've chosen to mirror your grocery list
  to, and local app preferences.
- We — the developer — do not operate a database of your data. We cannot see your recipes,
  meal plans, grocery lists, guests, or allergy information.

### 2. Household sharing

If you invite someone to your household (using Apple's built-in iCloud sharing), they get
access to the **entire shared household zone** — this is an all-or-nothing share, not a
curated subset. That means a household partner who accepts your invitation can see everything
listed under "household data" in §1 above, including **guest names, allergies, and dietary
notes** you've entered for events. Your personal, private-plane data (§1) — your own dietary
goals, your own private ingredient preferences, and your AI assistant chat history — is never
shared with a household partner, even if you share everything else.

Either the household owner or a participant can stop a share or leave a household at any time,
using Apple's standard iCloud sharing controls. Doing so removes that person's access to the
shared zone going forward; it does not retroactively un-share data they already saw or synced
locally while they had access.

### 3. AI features — your own key, sent directly to your chosen provider

SimmerSmith's AI features (weekly meal-plan generation, the in-app assistant, event/party menu
suggestions, recipe suggestions and variations, ingredient substitutions, and AI-generated
recipe images) are **"bring your own key" (BYO-key)**. You enter your own API key for a
provider in Settings; the key is stored only in this device's iOS Keychain (see §4a) and is
**never sent to SimmerSmith or to iCloud.**

When you use an AI feature, your iPhone sends a request **directly to the provider you
configured** — not through any SimmerSmith server, because none exists. Depending on the
feature, that request can include:

- Recipes, meal plans, grocery items, and pantry staples relevant to what you asked for.
- Your personal dietary goals and ingredient preferences, **including anything you've flagged
  as a personal allergy** — these are sent as hard constraints so the AI avoids them.
- When planning an event's menu: the **guests you've added, including each guest's name, age
  group, allergies, and dietary notes** — this is sent so the AI can avoid allergens for
  specific people at the event.
- Free-text you type or dictate to the assistant, and (if you use voice meal planning and
  on-device speech parsing isn't available) the text transcript of what you said.
- For recipe images: a short description of the recipe you're generating art for.

The AI assistant can also read and, when you ask it to, create or update your recipes, meal
plans, and grocery lists on your behalf — those actions happen through the same direct,
BYO-key connection.

**Text/planning providers you can choose:** OpenAI, Anthropic, or OpenRouter.
**Image-generation providers you can choose:** OpenAI or Google Gemini (a separate key).

**Once your data reaches your chosen provider, that provider's own privacy policy and terms
govern how they handle it** — SimmerSmith has no control over that and this policy doesn't
cover it. If you choose **OpenRouter**, be aware it is a routing service: depending on which
model you select through it, your request may ultimately be processed by a different
underlying AI company (for example Z.ai, Moonshot AI, MiniMax, DeepSeek, Meta, or Alibaba,
depending on the model slug you pick) in addition to OpenRouter itself. We recommend reading
the privacy policy of whichever provider(s) you choose before entering an API key.

If you don't want any of your data sent to a third-party AI provider, simply don't add an API
key — AI features won't work, but the rest of the app (manual recipes, meal planning, grocery
lists, Reminders sync) works fully without one.

#### 4a. Where your API key lives

Your AI provider API key is stored using Apple's Keychain Services, scoped to this device, with
an accessibility level that keeps it available only after you've unlocked the device at least
once since restart, and that is **not included in iCloud Keychain sync** — it does not travel
to your other devices and is never written to CloudKit. Saving a new key replaces the old one;
clearing it from Settings deletes it from the Keychain.

### 5. Reminders access

If you turn on grocery-list-to-Reminders sync, SimmerSmith asks for full access to Reminders
(so it can both create items and detect when you check them off in the Reminders app). It only
reads and writes the **one Reminders list you choose** — it never looks at or modifies any of
your other reminders lists. What gets written is the ingredient name, quantity/unit, store
label, and any notes; no guest, allergy, or dietary information is ever written to Reminders.
Checking an item off in the Reminders app, or adding a brand-new reminder directly to that
list, syncs back into SimmerSmith's grocery list; deleting a reminder in the Reminders app does
not remove the corresponding grocery item (this is deliberately one-directional to avoid data
loss from partial syncs). This sync can happen automatically in the background via iOS
background refresh, purely to reconcile Reminders with your grocery list — no server is
contacted for this.

### 6. Notifications

SimmerSmith can send **local notifications** you control from Settings — meal reminders,
grocery-day reminders, and cook-mode timers — generated and delivered entirely on your device.

Separately, the app registers for Apple's remote-push service, but **only so Apple's CloudKit
sync engine can receive silent "something changed" pushes** that tell your devices to check
iCloud for updates. No visible notification content is ever delivered this way, and no
SimmerSmith server sends you push notifications — there isn't one. Your device's push token
isn't transmitted anywhere by the app.

### 7. Camera, microphone, and speech recognition

- **Camera** is used only if you choose to scan a barcode or ingredient.
- **Microphone and on-device speech recognition** are used only for hands-free voice commands
  during cook mode (saying "next"/"previous" to move through steps) and for optional
  voice-dictated meal planning. Speech-to-text happens on-device; SimmerSmith does not request
  photo-library access for recipe photos.

### 8. Recipe images

AI-generated recipe header images are stored as file attachments in your household's iCloud
zone, alongside the rest of your household data (see §1–2) — the same sharing rules apply.

### 9. Backups and export

SimmerSmith can keep an on-device backup snapshot of your household data and lets you export it
as a file (using the standard iOS "Save to Files" / share sheet) or import a previously exported
file. A backup/export file can include your recipes, meal plans, events and their guests
(including allergy and dietary-note fields), grocery-related settings, pantry items, and
household settings — the same categories of data listed in §1. **A backup file never includes
your AI provider API key** (keys live only in the device Keychain and are never touched by the
backup code) and does not include recipe images. Backup files are stored locally on your device
and only leave it if you explicitly export and share one yourself; SimmerSmith does not upload
backups anywhere.

### 10. Subscriptions

SimmerSmith does not currently require or process any paid subscription — the app is free to
use at launch. If in-app purchases are enabled in a future update, purchase and entitlement
data will be handled by Apple's StoreKit under Apple's own privacy practices; we'll update this
policy before that happens.

### 11. Data deletion

- **Deleting an individual recipe, event, guest, or other item** in the app removes it from
  iCloud (and from a shared household zone, if applicable) the next time your device syncs.
- **"Clear Local Cache" and "Reset Connection / Sign Out"** in Settings remove data cached on
  *this device only* — your data in iCloud is not touched and re-syncs the next time you use
  the app.
- **To remove your household data from iCloud entirely**, delete the relevant items in-app, or
  use iOS's own iCloud data-management tools (Settings app → your name → iCloud) to manage or
  delete data associated with SimmerSmith, in addition to leaving or stopping a shared
  household (§2).
- **Deleting the app** removes on-device caches and your locally stored AI API key, but does
  not delete your data from iCloud — reinstalling and signing back into the same iCloud account
  restores it.

### 12. Children

SimmerSmith is not directed at children and is not intended for use by children without a
parent or guardian managing the account. We do not knowingly collect data from children in a
way that differs from any other user, and — as described throughout this policy — we don't
operate a server that collects anyone's data in the first place.

### 13. Changes to this policy

If how SimmerSmith handles data changes — for example, a new AI provider option, a new synced
feature, or (per §10) if subscriptions become active — we'll update this policy and change the
"Last updated" date below.

### 14. Contact

For privacy questions or requests, contact
[support@finklea.dev](mailto:support@finklea.dev).

Last updated: [DATE]

---

## Open questions for the human reviewer (not part of the published policy text)

These came up verifying the code against this draft and need a product/engineering decision —
they are flagged here rather than silently resolved one way or the other:

1. **"Memories" (recipe cook-log) feature still calls the legacy Fly API, unconditionally.**
   `RecipeMemoriesSection` (shown on every recipe detail screen, unlike `RecipePairingsCard`
   which IS correctly hidden behind `appState.isCloudKitOnly`) always calls
   `apiClient.fetchRecipeMemories` / `createRecipeMemory` / `fetchRecipeMemoryPhotoBytes` /
   `deleteRecipeMemory`, which hit `https://simmersmith.fly.dev/api/recipes/{id}/memories...`
   via the legacy `SimmerSmithAPIClient` — including uploading any photo you attach to a memory
   entry, base64-encoded in the request body. (Refs: `RecipeDetailView.swift:495` vs `:505`,
   `RecipeMemoriesSection.swift`, `AppState+Recipes.swift:1141-1182`,
   `SimmerSmithAPIClient.swift:1503-1553`.) For a brand-new CloudKit-only installer with no
   server URL ever configured, `ConnectionSettingsStore.load()` returns an empty
   `serverURLString`, and `SimmerSmithAPIClient`'s request builder guards on a non-empty base
   URL (`SimmerSmithAPIClient.swift:2249-2251`) — so in practice this errors out locally (shown
   as an inline error in the UI) rather than actually reaching Fly, **for users who never had a
   Fly connection configured.** But: (a) this is existing, tracked work — bead
   `simmersmith-990.4` ("SP-D: recipe memories to CloudKit") is open and specifically covers
   rewiring this UI onto CloudKit; (b) I could not confirm from code alone whether
   `simmersmith.fly.dev` is still live/reachable, so I can't rule out a real network call
   reaching a real server for any user who *does* still have a legacy connection saved from
   before the pivot. **This directly contradicts a blanket "no server" claim** — I did not
   soften §1's "no server" framing to account for this one feature because doing so would make
   the policy read as hedging on its central claim; instead I recommend one of: (a) gate
   `RecipeMemoriesSection` behind `isCloudKitOnly` like its sibling before shipping this policy,
   (b) confirm `simmersmith.fly.dev` is fully decommissioned/unreachable so the guard always
   fires, or (c) if neither happens before launch, add an explicit caveat sentence to §9 or a
   new short section about this one feature. I'd default to (a) since bead 990.4 already exists
   to do exactly that.

2. **RESOLVED 2026-07-07 (Fable):** this was a real P1 — filed and fixed same-day as bead
   `simmersmith-13j` (`ca0cb5f`): `init?(recordTypeName:)` reverse mapping + regression tests;
   adversarially verified. §9's content description is now accurate in practice, not just by
   design. Original finding kept below for the record.
   **Household backup/export may currently produce empty backups (separate from the policy
   text, but affects whether §9's content description is currently accurate in practice).**
   `AppState+Backup.swift:52`'s `snapshotHousehold()` does
   `HouseholdRecordType(rawValue: record.recordType)`, but `HouseholdRecordType`'s Swift-
   synthesized raw values are lower-camelCase (`"recipe"`, `"guest"`, …) while
   `record.recordType` is the PascalCase `recordTypeName` (`"Recipe"`, `"Guest"`, …) actually
   written to CloudKit (`HouseholdRecordCodec.swift:14-16`) — the two never match, so this
   guard likely always fails and every record is silently skipped. §9 describes what a backup
   is *designed* to contain (which is the right thing for a privacy policy to describe — it's
   describing worst-case exposure, not current bugs), but I'd flag this so someone exports a
   real backup and inspects the file's `records` array before this ships, since if it really is
   empty, that's a separate P1-adjacent bug worth its own bead independent of this policy.

3. **GLM (Z.ai) / Kimi (Moonshot) / MiniMax exist as BYO-key vendors in `AIProviderKit` but are
   not reachable from current Settings UI** (`OpenModelsPickerRow` hardcodes the vendor to
   `.openRouter`; only a user who saved one of these three from a now-removed older picker
   still has it persisted, via `AppState+AI.swift:232`). I left them out of the published
   policy since a policy should describe what users can actually do today, but flagged them in
   the ASC label notes file in case Apple's review or a future audit needs the full historical
   picture.

4. **Apple Sign-In code (`AppState.signInWithApple`) is present but not reachable from any
   current UI** — it exists only for a one-time legacy Fly-migration auth path
   (`RootView.swift` comment: "Sign in with Apple is removed from this gate — iCloud IS the
   identity now"). I omitted it from the policy since normal users never encounter it; flag if
   you'd rather it be mentioned for completeness/legacy-user transparency.

5. **(Added by Fable, 2026-07-07) Hosting facts for the 990.11 decision:** the current policy
   at `docs/privacy/index.html` is ALREADY deployed by GitHub Pages on every push (the
   "pages build and deployment" CI job; no CNAME, so it serves at the default github.io URL) —
   the re-host may reduce to "port this draft into docs/privacy/index.html, push, and point ASC
   at the Pages URL". Verify what URL ASC currently lists (likely fly.dev). Also:
   `PaywallSheet.swift:70` hard-codes `https://simmersmith.fly.dev/privacy` — dark at launch
   (ADR-2) but it's a user-facing fly.dev reference (Gate-3 rule); update it to the final URL
   when chosen. Contact email `support@finklea.dev` verified as carried over from the published
   policy, not invented.
