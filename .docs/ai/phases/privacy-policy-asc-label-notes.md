# App Store Connect privacy nutrition label — mapping notes (bead simmersmith-5w8)

> Companion to `privacy-policy-cloudkit-draft.md`. This is a **starting map**, not a filled-in
> label — the ASC "App Privacy" questionnaire wording and category list changes over time and
> requires being logged into App Store Connect to fill out; I have not done that (out of scope
> for this pass — the bead's acceptance criteria says the human does the ASC step). Where I'm
> not confident which ASC bucket applies, I've said so explicitly rather than guessing, per the
> task's instruction to flag uncertainty. Treat every row below as "propose, then verify against
> the live questionnaire," not "enter verbatim."

## Ground truth this mapping is based on

- No SimmerSmith server exists for the data plane. Household + personal data lives in the
  user's own iCloud (CloudKit private DB + a shared "household" CKShare zone). See the policy
  draft §1–2 for exactly what's in each.
- AI features are BYO-key: the device sends data **directly** to a third-party provider the
  user configures (OpenAI, Anthropic, or OpenRouter for text; OpenAI or Gemini for images) using
  the user's own API key. SimmerSmith itself never receives or stores this data server-side.
- One known exception, currently unresolved (see draft's "Open questions" item 1): the recipe
  "Memories" feature still unconditionally calls a legacy Fly-hosted API
  (`simmersmith.fly.dev`) for text + photo memory entries. Whatever the human decides there
  (gate it off vs. confirm the endpoint is dead vs. disclose it) changes whether this label
  needs a "server-collected" declaration for that one data type. **Don't finalize the label
  until that's resolved** — if the Memories feature ships live-wired to Fly, the label must
  account for a first-party server collecting free-text + photos, which is a materially
  different declaration than "third party, user-initiated, BYO-key."

## The core judgment call: does BYO-key third-party transmission count as "data collection"?

Apple's own guidance (App Privacy Details, developer documentation) treats data your app
transmits off-device — including to a third-party API the user configures with their own
credentials — as data that must be evaluated for the label, UNLESS your app **truly never
transmits it anywhere** (Apple's narrow "Data Not Collected" bar). A user pasting their own
OpenAI key and the app then sending recipe/allergy text to OpenAI's API is very plausibly
"collection by a third party through your app" in Apple's framing, even though:

- SimmerSmith (the developer) never receives or stores that data itself, and
- the user opted in by choosing to add a key at all (AI features are fully optional).

**I'm flagging this as the single biggest judgment call in this whole document** — whether
"BYO-key, user-configured, device-to-provider, feature fully optional" changes the declaration
vs. a traditional embedded third-party SDK. I don't have high confidence reading Apple's
documentation from training data is authoritative for the *current* ASC questionnaire wording
(it has been revised more than once). Recommend the human either check the current
questionnaire text directly in App Store Connect, or have counsel confirm before answering "is
this data collected" for the AI-related rows below. My working assumption for the rows below is
the cautious one: **treat BYO-key AI transmission as collection**, attributed to the third-party
provider, purpose "App Functionality," not linked to identity (no account exists to link it to).

## Proposed data-type mapping

| ASC category (as of recent ASC versions) | Applies? | Notes |
|---|---|---|
| **Contact Info** (name, email, phone, address, other) | Likely No | No account/sign-up. Guest *names* are entered by the user for menu planning and sync to their own iCloud + BYO AI provider, but this is arguably "User Content" (guest data you created), not "Contact Info" about the *app user*. Flag: Apple's guidance on whether *other people's* names a user enters counts under Contact Info vs. User Content is not something I can resolve confidently — verify against current questionnaire framing. |
| **Health & Fitness** | **Uncertain — flag for human/legal** | Guest and personal **allergy** and **dietary notes/goals** data is sent to third-party AI providers and stored in iCloud. Apple's "Health & Fitness" category is specifically scoped to health/medical/fitness data; allergy information arguably qualifies as health-adjacent, but Apple's own examples lean toward clinical/medical apps (symptoms, medications, fitness metrics) rather than a food-allergy note in a meal planner. This is exactly the kind of call that determines whether a stricter label section applies. **Do not guess here — confirm against Apple's current definitions before submitting.** |
| **Financial Info** | No | No payment collection currently (paywall is dark, StoreKit-only, no server-side receipt handling). Apple's own standard purchase-history disclosure may still apply at the platform level regardless of app-specific code — check ASC's standard guidance if/when the paywall activates. |
| **Location** | No | No location APIs used anywhere found in the app. |
| **Sensitive Info** (racial/ethnic, sexual orientation, pregnancy, religious beliefs, etc.) | No | Not collected. |
| **Contacts** (device contacts/address book) | No | No Contacts framework usage found. |
| **User Content** — Photos or Videos | **Likely Yes, "not linked to you" / App Functionality** | AI-generated recipe header images are stored as CKAsset in the user's iCloud household zone (Apple's own service, app functionality only). If the "Memories" photo-upload feature is confirmed live against Fly (see ground-truth note above), that would instead need declaring as first-party-server-collected photos — different bucket, flag until resolved. |
| **User Content** — Other User Content (recipes, meal plans, grocery lists, notes, guest/allergy text) | **Likely Yes, when an AI feature is used** | This is the core of what's sent to the BYO AI provider. Purpose: App Functionality. Recommend declaring the underlying data categories that flow into these fields (see Health & Fitness flag above) rather than lumping everything as generic "Other User Content" if the questionnaire forces a more specific choice. |
| **User Content** — Audio Data | **Uncertain — likely No, but flag** | Voice input (cook-mode navigation, voice meal planning) is transcribed **on-device** via `SFSpeechRecognizer`/on-device recognition per the Info.plist usage strings — raw audio itself is not sent anywhere in the code I read. Only the resulting **text transcript** may be sent to the BYO AI provider as a text-parsing fallback (`CloudParseService.swift`). If Apple's label distinguishes "audio recorded" from "text derived from audio," this should land as text/User Content, not Audio Data — but verify, since the mic permission itself may still trigger an audio-adjacent prompt in the questionnaire flow. |
| **Browsing History / Search History** | No | Not applicable; app has no web browsing feature. |
| **Identifiers** — User ID | No | No account system; iCloud identity is Apple's, not a SimmerSmith-issued ID. |
| **Identifiers** — Device ID | **Uncertain — flag** | The app registers for APNs (`registerForRemoteNotifications`) solely to receive CloudKit's silent push, and the device token is explicitly a no-op (never transmitted anywhere by app code — see `PushService.swift`). Likely No, but the mere act of registering for push sometimes trips a "did you use this capability" checkbox in the questionnaire regardless of whether the token is sent anywhere; verify against the live form. |
| **Purchases** | No, currently | Paywall is dark/inert (ADR-2: local StoreKit 2 truth only, no server-side receipt validation, `MonetizationFlags.paywallEnabled = false`). Revisit this row the moment the paywall is turned on. |
| **Usage Data / Diagnostics / Analytics / Crash Data** | No | No analytics SDK, no crash-reporter SDK, no MetricKit integration found anywhere in the current source tree (`grep` for `MetricKit`/`MXMetricManager` returned zero hits). **Do not declare any analytics/diagnostics collection** — this is a real gap vs. the old policy's claim of "no analytics," and the current code still supports that claim. (MetricKit is on the roadmap per `.docs/ai/decisions.md`'s 2026-07-01 ADR amendment, but is NOT shipped — re-check this row if/when it lands.) |
| **Other Data** | Possibly | Household term aliases, pantry staples, and household settings sent to the BYO AI provider as planning context could fall here if not covered by "Other User Content" above — likely a wording/consolidation choice in the questionnaire rather than a separate substantive declaration. |

## Linked-to-identity and tracking questions

- **Linked to identity:** There is no SimmerSmith account, but data does sync to the specific
  user's iCloud account, and household data is associated with a specific household. Whether
  ASC considers "linked to the user's Apple ID via CloudKit, but not to any identifier
  SimmerSmith itself assigns" as "linked" or "not linked" is another judgment call — flag for
  human confirmation; I'd lean "not linked to an identity SimmerSmith controls" for the BYO-key
  provider leg specifically, since the app never sends any user identifier to the AI provider
  (no account ID, no device ID) — only the content of the request itself.
- **Tracking (per Apple's ATT-adjacent definition — combining data with third parties for
  advertising, or sharing with data brokers):** No. There is no advertising SDK, no analytics
  SDK, and BYO-key AI usage is the user directly using a service of their own choosing for a
  feature they invoked — not SimmerSmith linking data across apps/websites for ads. This row
  should be a confident **No** for App Tracking Transparency purposes.

## Recommended next steps for the human

1. Confirm the "Memories"-still-calls-Fly item (see policy draft's open question #1) before
   finalizing any row above that assumes "no first-party server."
2. Resolve the Health & Fitness bucket question for allergy/dietary data — this is the row most
   likely to be wrong if guessed, and it changes what App Store review expects to see disclosed.
3. Resolve the "does BYO-key, user-initiated, device-to-provider transmission count as
   collection" framing question — ideally by re-reading the live ASC questionnaire copy at fill
   -in time, since Apple revises this periodically and I can't verify current wording without
   ASC access.
4. Re-check the Purchases row if/when the paywall (currently dark) is ever turned back on.
5. Re-check the Diagnostics/Analytics row if/when MetricKit ships (tracked in decisions.md /
   roadmap, not yet in code).
