# JFN Deterministic Onboarding

Date: 2026-08-07
Status: owner-approved design; implementation pending
Roadmap: Wk4 product depth, `jfn`
Decision authority: `decisions.md` ADRs dated 2026-07-09, 2026-07-14, and 2026-08-07

## Goal

- Give a newly created household a four-screen, fully keyless setup path before normal app use.
- Capture load-bearing planning inputs with immediate consumers — household size, ingredient
  avoids/allergies, and liked cuisines — plus the device timezone for later localized scheduling.
- Let a first-run user reach the normal Week surface without an AI call or API-key dead end.

## Eligibility

- Automatic onboarding is created only by the authoritative CloudKit path that mints a household.
- Carry an explicit `newly minted` origin through household boot. Do not infer newness from empty
  weeks, recipes, preferences, install age, or an absent onboarding setting.
- An existing household with no onboarding state is ineligible for automatic presentation.
- A participant joining an existing household is ineligible for automatic presentation.
- Settings can launch onboarding manually for any ready household, regardless of automatic
  eligibility or lifecycle state.
- Present automatically only after the household session and private plane are ready.

### Mint crash receipt

- Before committing the newly generated household ID to CloudKit, persist an install-local receipt
  containing that exact ID and onboarding version.
- After a matching household resolves, ensure its private onboarding state is `pending`; clear the
  receipt only after that state is durably saved.
- A receipt that does not match the authoritatively resolved household must never make onboarding
  eligible. It may be cleared after authoritative resolution proves the mismatch.
- The receipt is recovery evidence only. Private profile state is authoritative after initialization.

## Lifecycle state

Private profile settings carry onboarding version 1:

- `onboarding_version`: `1`
- `onboarding_state`: `pending` | `completed` | `retired`
- `onboarding_dismiss_count`: nonnegative integer encoded as a string
- `onboarding_snooze_until`: ISO-8601 timestamp, empty when not snoozed
- `onboarding_draft`: stable JSON for a normalized completion intent, empty outside an interrupted
  completion

Automatic presentation policy:

- `pending`, zero dismissals, no future snooze: present.
- First automatic **Skip for now**: keep `pending`, set dismiss count to 1, and snooze for 24 hours.
- While the snooze timestamp is in the future: do not present.
- First ready launch at or after the timestamp: present again.
- Second automatic dismissal: set `retired`, set dismiss count to 2, clear the snooze, and never
  auto-present again.
- Successful completion from automatic or manual presentation: set `completed`, clear the snooze,
  and never auto-present again.
- Cancelling a Settings-launched flow does not change dismissal count or lifecycle state.
- Unknown or malformed lifecycle values do not auto-present; Settings remains the recovery path.

When automatic onboarding first presents, mark the current release-notes version seen so onboarding
and What's New never stack on a brand-new household.

## User flow

Use one full-screen SwiftUI flow with visible progress, Back, and an automatic-mode **Skip for now**
action. Every field is optional; the primary action is never gated on an AI provider or key.

1. **Household size**
   - Ask how many people meals normally serve.
   - Range: 1 through 12.
   - Initial value: 4, preserving existing behavior.
2. **Avoids and allergies**
   - Reuse the canonical ingredient catalog search/browse pattern from Settings.
   - Each selection is classified as `avoid` or `allergy`.
   - Persist real active `IngredientPreference` rows with catalog ID and human-readable name.
3. **Favorite cuisines**
   - Multi-select from the managed cuisine metadata list.
   - Empty selection is valid.
4. **Plan setup**
   - State the current Monday-through-Sunday week model; do not offer a week-start picker.
   - Show and save `TimeZone.current.identifier` as the IANA timezone.
   - Summarize the selected planning inputs before **Done**.

Settings adds a **Meal planning setup** row that opens the same flow prefilled from current profile
settings and active avoid/allergy preferences. In manual mode, use **Cancel** instead of advancing the
automatic dismissal policy.

## Persistence and completion

Store these explicit planning settings in the existing private profile settings map:

- `household_size`: integer string in the range 1...12
- `liked_cuisines`: stable JSON string array of canonical display names
- `timezone`: valid IANA identifier

Onboarding lifecycle keys and planning keys must remain excluded from generic AI-visible profile
settings. Planning consumers receive only the explicit values they need.

The view owns an in-memory draft before submission. Dismissing does not partially apply it. **Done**
uses a retryable, idempotent completion coordinator:

1. Validate and normalize the draft.
2. Persist the normalized draft as `onboarding_draft`; stop before domain writes if this fails.
3. Reconcile the complete active `avoid`/`allergy` logical set by `(baseIngredientID, choiceMode)`;
   reuse existing rows and create no duplicates. Do not touch other preference modes.
4. Persist household size, cuisine list, and timezone.
5. Reload and verify that private-plane projections match the normalized draft.
6. Persist `onboarding_state = completed` as the final semantic write.
7. Clear `onboarding_draft` and any matching mint receipt as idempotent cleanup.

Repository writes used by completion must report failure to the coordinator instead of only logging
it. A write or verification failure keeps the flow open with a retry action and never marks completion.
If the process dies after a partial write, the still-pending lifecycle reloads the durable draft intent
and converges it without duplicate preferences.

## Planning integration

- Add `defaultServings` to `PlanningContext`, defaulting to 4 for absent or invalid profile state.
- `WeekGenContextGatherer` reads `household_size` and the explicit cuisine list.
- Week-generation prompts state the default servings explicitly and use it in the response example.
- Assistant planning context exposes the same default so assistant-proposed household meals use it.
- Recipe-generation entry points use the household default only when no positive serving count was
  supplied. Explicit values always win.
- Event planning remains attendee-count driven and must not inherit household size.
- Merge explicit liked cuisines ahead of learned cuisine signals, normalized case-insensitively.
  Remove an explicitly liked cuisine from the derived dislike set.
- Keep the existing avoid/allergy behavior: allergies also enter hard avoids and remain the source
  for the post-generation allergy gate.
- Timezone is persisted for later localized scheduling. This phase does not change `WeekBoundary`,
  Monday week arithmetic, or UTC date serialization.

## Presentation and failure behavior

- Automatic onboarding is a single root-level full-screen presentation; it must not race the paywall
  or release-notes sheet.
- Catalog or metadata loading failures show retryable, honest empty/error states. They do not trigger
  an AI fallback and do not fabricate ingredient IDs or cuisine names.
- Completion shows progress, disables duplicate submission, and remains on screen on failure.
- Support Dynamic Type, VoiceOver labels/values, keyboard focus, and Reduce Motion. Progress and
  selection state must not be conveyed by color alone.

## Non-goals

- No conversational or AI-powered preference interview.
- No custom week-start support or week-boundary refactor.
- No new CloudKit record type, shared household schema, backend, Fly.io, or web code.
- No migration that auto-enrolls existing households and no empty-household heuristic.
- No keyless AI generation gateway, subscription change, TestFlight upload, or release action.
- No change to the pending cache-first-OFF crash-durability device gate.

## Tests and acceptance

- Exact new mint initializes pending onboarding; discovered/existing and joined households do not.
- The mint receipt recovers a crash between mint and private-state initialization; mismatched receipts
  never present onboarding.
- First automatic dismissal stays hidden before 24 hours and becomes due at/after 24 hours.
- Second automatic dismissal retires the prompt; manual Settings launch still works.
- Completion and retired states never auto-present; malformed state fails closed.
- Automatic presentation suppresses the current What's New sheet.
- Completion is idempotent across partial failure and produces no duplicate avoid/allergy rows.
- A crash after draft staging reconstructs every submitted choice before retrying completion.
- Allergies reach both the emphasized allergy context and hard avoids.
- Explicit cuisines merge before learned likes and override matching learned dislikes.
- Household size reaches week, assistant, and default recipe-generation serving context; explicit
  servings and event attendee counts retain precedence.
- Timezone round-trips as a valid IANA identifier; Monday/UTC week behavior is unchanged.
- Existing households without onboarding state retain 4-serving behavior and never auto-present.
- The complete flow performs zero AI-provider calls.

## Verify

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithCloudKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate --spec SimmerSmith/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
git diff --check
```
