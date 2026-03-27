# SimmerSmith Handoff

Use this file as the starting prompt/context for the next session in `/Users/tfinklea/git/simmersmith`.

## Recommended Session Prompt

```text
You are continuing work on SimmerSmith from /Users/tfinklea/git/simmersmith.

Read HANDOFF.md first, then inspect the repo state before making changes.

Important product direction:
- SimmerSmith is Apple-first.
- The FastAPI app is the canonical server and state layer.
- iOS is the primary client.
- The web app is now a secondary admin/proving surface.
- Prefer modern native SwiftUI components and Apple-provided Liquid Glass styling wherever possible.
- Do not invent custom components when a native control is sufficient.
- When doing iOS work, use strong SwiftUI judgment and keep architecture aligned with a shared package + typed API client + native persistence approach.

Immediate priority:
1. Finish the Recipes platform on iOS so it is strong enough for real weekly planning.
2. Only after Recipes are solid, build the guided planning wizard for future weeks.

Before coding:
- Check git status.
- Read this handoff fully.
- Inspect the dirty Xcode project diff noted below and decide whether to keep or revert it before further work.
```

## Current Repo State

- Local path: `/Users/tfinklea/git/simmersmith`
- Public repo: `https://github.com/TaylorFinklea/simmersmith`
- Product domain: `https://simmersmith.app`
- License: `AGPL-3.0`
- Local git history was intentionally reset during the rename/rehome. Current root history is new and public-safe.

### UI follow-up TODOs

- Revisit the iOS app icon source once a corrected Photoshop export is available.
- Current issue: the mark-only icon asset is slightly off-center, so regenerate the iOS app icon set from the corrected source before doing any final icon polish for glass/clear/tinted modes.

### Current commits

- `c440b2e` `chore: rehome as SimmerSmith`
- `a32ea58` `chore: remove local workspace artifacts`

### Current known dirty file

At handoff time, the worktree was clean except for:

- `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`

Current diff:

- adds `DEVELOPMENT_TEAM = K7CBQW6MPG;` in two build settings blocks
- changes `SimmerSmith.app` file reference from `lastKnownFileType` to `explicitFileType`

This looks like normal Xcode local project regeneration/signing drift, not product logic. Decide early in the next session whether to:

- keep it and commit it intentionally, or
- revert/regenerate it before feature work

## Rename / Rehome Status

Completed:

- Project renamed from `Mealplanner` to `SimmerSmith`
- Repo moved from `/Users/tfinklea/git/mealplanner` to `/Users/tfinklea/git/simmersmith`
- Public GitHub repo created at `TaylorFinklea/simmersmith`
- Homepage set to `https://simmersmith.app`
- Bundle IDs moved to:
  - `app.simmersmith.ios`
  - `app.simmersmith.ios.tests`
  - `app.simmersmith.ios.uitests`
- Swift package renamed to `SimmerSmithKit`
- Env var namespace moved to `SIMMERSMITH_*`
- Tracked local token artifact `.tmp-ios-token` was removed
- Repo was published after a basic secret sweep

Still outstanding:

- Old repo deletion was blocked by GitHub auth scope. The previous session could not delete `TaylorFinklea/mealplanner` because the current `gh` token lacked `delete_repo`.

If you want to finish that later:

```bash
gh auth refresh -h github.com -s delete_repo
gh repo delete TaylorFinklea/mealplanner --yes
```

## Product Direction

SimmerSmith is no longer “web-first mealplanner with an iOS companion.”

It is now:

- `server + iOS` as the core product
- optional future `macOS` as the richer operator client
- web as a secondary admin/proving surface

Guiding principles:

- Server owns canonical state and business logic.
- iOS gets the primary UX investment.
- Use native SwiftUI components and system behaviors by default.
- Use Apple Liquid Glass styling where the platform already provides it.
- Avoid building custom UI abstractions unless a specific use case forces it.

## Architectural Snapshot

### Server

- FastAPI app under `app/`
- SQLite as canonical storage
- Alembic migrations under `alembic/versions/`
- Optional bearer-token auth via `SIMMERSMITH_API_TOKEN`
- Domain areas already in place:
  - profile/preferences
  - recipes
  - weeks
  - grocery
  - pricing/imported retailer data
  - exports / Apple Reminders queueing

### iOS

- Xcode project in `SimmerSmith/`
- Shared package in `SimmerSmithKit/`
- Modern SwiftUI app with:
  - `TabView`
  - `NavigationStack`
  - `List`
  - `Form`
  - `searchable`
  - sheets
  - native editors and pickers
- Uses shared typed networking and local cache/persistence patterns

### Web

- React/Vite/Tailwind app in `frontend/`
- Still useful as an admin/proving surface
- No longer the long-term primary experience

## What Has Already Been Implemented

### Earlier web/server groundwork

These shipped before the Apple-first pivot and still matter because the server model depends on them:

1. Manual week planning foundation
   - Users can author weeks manually instead of relying only on AI draft flows.

2. Manual recipe authoring and reuse
   - CRUD for recipes
   - archive/restore/delete
   - reusable editor flows

3. Recipe URL import and source provenance
   - URL import pipeline
   - source tracking and source metadata

### Apple-first foundation

4. iOS companion foundation
   - SwiftUI iOS app target created
   - `SimmerSmithKit` shared package created
   - bearer-token auth supported by server
   - mobile-safe freshness metadata added
   - iOS surfaces for week, grocery, recipes, activity, settings

5. iOS recipe editing and week assignment
   - browse/search/sort recipes
   - create/edit recipes on iOS
   - create linked variants
   - batch assign recipes into future week slots
   - conflict-aware assignment flow

6. Recipe hardening
   - managed cuisines instead of pure freeform
   - managed tags with chip-style behavior
   - managed ingredient units
   - recipe scaling presets (`1/4`, `1/2`, `1x`, `2x`, `4x`)
   - nested instructions with one level of substeps
   - better recipe filtering/sorting on iOS
   - improved import shaping

7. Calories / nutrition estimation
   - server-side calorie estimation from ingredients
   - nutrition catalog and ingredient matching
   - calories per serving
   - variation-aware recalculation
   - iOS editor/detail views for calorie preview and nutrition matching

### Important iOS fixes already landed

- startup sync no longer hard-fails on recipe fetches
- connection screen no longer disappears after the first typed character
- server setup URL normalization is fixed
- naive server datetimes decode correctly
- snake_case decoding mismatches were fixed
- misleading placeholder text in imported ingredient rows was fixed

## Recipe Domain: Current Shape

Recipes are the current highest-priority area.

The user’s intended real workflow is:

1. Go to Recipes first.
2. Browse likely dinners and breakfasts.
3. Select promising recipes and assign them into a future week.
4. Submit the partial week.
5. Use AI to fill gaps or collaborate after the human-selected recipes are in place.

That means Recipes have to be “rock solid” before the planning wizard.

### Recipe capabilities already present

- base recipes
- linked variants
- structured ingredients
- nested steps/substeps
- tags
- cuisine
- source attribution
- source URL import
- memories/notes fields in the model
- calorie estimates from ingredient resolution
- week assignment from recipes

### Important recipe requirement from the user

Variant flow must be practical for real substitutions, not decorative.

Concrete example:

- base: Pad Thai
- desired variant: low-carb Pad Thai using carrots instead of noodles

If the variant exists already, it should be easy to pick it.
If it does not exist yet, it should be easy to create/save it from the base recipe and then select between the base and the variation.

If that flow is awkward, the whole planning model breaks down.

## What Still Needs To Be Done

## Highest priority: finish Recipes before planning wizard

This is still the next major execution track, but the state of the work needs to be described more accurately.

What is already in code but still needs hardening:

- scan/photo/PDF recipe import exists, but it still needs a real regression corpus, OCR hardening, and trust-building polish
- AI variation drafts exist, but AI suggestion drafts and companion suggestions still need to be built
- the template model exists, but native PDF export and user-facing template customization do not

### Expanded roadmap: next execution phases

### 1. AI recipe suggestions

Needed:

- draft-only “what should I cook next?” suggestions
- recipe suggestions grounded in saved recipes, tags, source history, and internet context
- the same draft-only review posture already used elsewhere

### 2. Recipe companion suggestions

Needed:

- “what goes well with this?” draft suggestions for sides, sauces, and pairings
- enough rationale that the user understands why the pairing was suggested

### 3. Import quality lab

Tech debt that should happen before more recipe intelligence piles on.

Needed:

- a permanent regression corpus for URL, photo, and PDF imports
- deterministic parser expectations for edge-case ingredients and OCR cleanup
- saved fixtures from real recipe sites and real scans

### 4. Scan/photo/PDF import hardening

Implemented in baseline form, but not trustworthy enough yet.

Needed:

- better OCR review and salvage behavior
- multi-page ordering hardening
- weak-scan fallback that preserves text without mangling it
- stress-testing on real cookbook photos, recipe cards, and PDFs

### 5. Native recipe PDF export v1

Needed:

- native iOS PDF export/share
- production-quality printable output from the existing recipe model
- templates that are usable without requiring layout tinkering each time

### 6. Template customization

Needed:

- user-facing export template selection and tuning
- continued alignment of recipes to a reusable template model
- a clear split between canonical recipe data and presentation rules

### 7. Live step and substep reorder

Needed:

- drag-and-drop step reorder in the native recipe editor
- reorder behavior that stays compatible with templates and export

### 8. Recipe experience polish

Still likely needed even after the above:

- ensure “last used” / “time since last used” are surfaced clearly and sort behavior feels useful
- make breakfast and dinner the most ergonomic discovery flows
- make variant selection/creation friction very low
- continue stress-testing import quality on real recipe sites
- review whether the cuisine/tag/unit managed-list UX feels native enough

### 9. SwiftUI architecture pass

Tech debt.

Needed:

- break the oversized `AppState` responsibilities into smaller domain-focused state/services
- reduce view-owned async orchestration and inline `Task {}` usage
- keep the app easy to reason about as planning and assistant features expand

### 10. Swift Concurrency cleanup

Tech debt.

Needed:

- move more work to structured concurrency
- tighten actor/isolation boundaries before more AI and planning state lands
- avoid papering over concurrency problems with blanket main-actor decisions

### 11. Swift Testing expansion

Tech debt.

Needed:

- parameterized Swift Testing coverage for parser/import/editor/template behavior
- stronger shared-package and iOS unit coverage where business rules live

### 12. iOS UI automation expansion

Tech debt.

Needed:

- broader XCTest UI coverage for onboarding, import, editing, variation, and week assignment flows
- keep device-class regressions visible before App Store submissions

## Next after Recipes: future-week planning wizard

This should not start until Recipes feel trustworthy.

### 13. Guided future-week planning wizard

Desired wizard direction:

- choose a future week
- browse/select recipes first
- emphasize dinner and breakfast
- lunch remains supported but secondary
- assign selected recipes into slots
- leave intentional gaps
- hand partial plan to AI afterward for collaboration/fill-in

The current codebase already has some week assignment plumbing, but not the full guided wizard.

### 14. Week staging/change-history hardening

Tech debt.

Needed:

- tighten diffing, approvals, and auditability for week changes
- make sure AI-assisted week changes remain reviewable and explainable

## Longer-Term Roadmap After That

These are still part of the broader product direction, but they are not the immediate next build order:

### 15. AI planning collaboration
- week-level and slot-level assist
- fill gaps after human picks recipes

### 16. Grocery workspace maturation
- editable grocery workspace
- manual and derived items together
- pricing invalidation behavior after edits

### 17. Pricing/store split/cart prep quality
- better trustworthiness and handoff quality

### 18. Kitchen Assistant for ingredients and seasonality
- in-app help for unfamiliar ingredients
- produce-picking guidance
- seasonality suggestions tied to the user’s context

### 19. Equipment intelligence
- household equipment inventory
- timing estimates and conversion suggestions based on actual owned equipment

## Priority Queue After Current Roadmap

After the current Recipes sequence, the planning wizard, and the grocery/pricing foundation, prioritize the following ideas next:

### 20. Recipe coaching and “what does this mean?” help
- explain recipe language inline, e.g. “3 cups milk, lukewarm” and what the user should actually do
- practical troubleshooting, e.g. “it was too watery, what should we change?”
- use the recipe context, current step, and saved variations where possible

### 21. Richer source fidelity from creator recipes
- preserve creator videos for imported recipes when the source page provides them
- keep the original creator recipe clearly visible alongside allowed substitutions/variations
- use the variations system to distinguish canonical recipe vs user/AI substitutions

### 22. Cooking education tracks
- beginner-friendly recipe paths for adults learning to cook
- kid-friendly recipe paths for children learning to cook
- skill-oriented learning flows, e.g. “learn to sauté”, “learn to bake bread”, etc.

### 23. Visual cooking feedback
- upload a picture of the current cooking step
- evaluate whether the user is on track or likely doing something wrong
- tie the feedback to recipe step context rather than making it generic

### 24. Guided recipe discovery and comparison
- search online for recipes by intent, e.g. “find me the best whole wheat waffle recipe”
- explain why a suggested recipe is considered best
- compare source credibility, technique, ingredient choices, and fit for the user’s saved preferences

### 25. iOS release pipeline hardening

Tech debt.

Needed:

- standardize archive/export/signing/App Store submission checks
- reduce one-off local release fixes
- make shipping builds more repeatable

### 26. iOS metadata/compliance synchronization

Tech debt.

Needed:

- keep Info.plist permissions, supported devices/orientations, support/privacy URLs, and icons aligned with shipped behavior
- keep submission docs aligned with the actual app

### 27. Web admin design-system consolidation

Tech debt.

Needed:

- normalize the frontend around semantic tokens and the current shadcn/Radix primitives
- avoid visual drift as the admin surface grows

### 28. Web end-to-end coverage with browser automation

Tech debt.

Needed:

- add real browser coverage for recipe import/edit, week review, grocery edits, and pricing review
- catch operator-flow regressions before they become daily friction

### 29. Cloudflare-hosted web frontend
- host the admin/frontend on Cloudflare rather than treating it as local-only forever
- prefer the same general hosting direction used elsewhere in the ecosystem

### 30. Cloudflare deployment and observability

Tech debt.

Needed:

- repeatable preview/production deployment
- basic logs and operational visibility for the hosted web surface

### 31. Public support/privacy/landing maintenance

Tech debt.

Needed:

- treat the GitHub Pages support/privacy surface as maintained product infrastructure
- keep the public-facing docs aligned with actual app capabilities

### 32. macOS operator client
- only after server contracts, iOS information architecture, and hosted web/admin workflows are stable

## Suggested Next Session Execution Order

1. Read this file.
2. Confirm the repo still builds cleanly.
3. Finish the remaining recipe-intelligence track in this order:
   - AI recipe suggestions
   - companion suggestions
   - import quality lab
   - scan/photo/PDF hardening
   - native recipe PDF export
   - template customization
   - live step/substep reorder
   - recipe experience polish
4. While doing the above, sprinkle in the iOS tech debt phases when they clearly reduce future complexity:
   - SwiftUI architecture pass
   - Swift Concurrency cleanup
   - Swift Testing expansion
   - iOS UI automation expansion
5. Only then build:
   - guided future-week planning wizard
6. After the wizard, do:
   - week staging/change-history hardening
   - AI planning collaboration
   - grocery workspace maturation
   - pricing/store split/cart prep quality
7. After that, expand into:
   - Kitchen Assistant / seasonality
   - equipment intelligence
   - recipe coaching
   - creator/source fidelity
   - education tracks
   - visual cooking feedback
   - guided recipe discovery/comparison
8. Treat these as continuing infrastructure tracks that should not be ignored:
   - iOS release pipeline hardening
   - iOS metadata/compliance synchronization
   - web admin design-system consolidation
   - web end-to-end coverage
   - Cloudflare hosting/deployment/observability
   - public support/privacy maintenance
9. Only after the above foundations are strong:
   - macOS operator client

## Validation Commands

These were the main validation commands used successfully during the rename/cutover work:

```bash
.venv/bin/pytest -q
cd frontend && npm test
cd frontend && npm run build
swift test --package-path SimmerSmithKit
xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' test CODE_SIGNING_ALLOWED=NO
```

If any path-related Swift package cache issue reappears because of the repo rename, reset package artifacts before retrying:

```bash
swift package reset --package-path SimmerSmithKit
```

## Notes For The Next Agent

- Keep the Apple-first posture. Do not slip back into treating the web app as the main product.
- Do not add custom UI abstractions unless native SwiftUI controls are insufficient.
- Maintain server-first business logic. iOS should consume clean APIs, not duplicate the logic.
- Do not reintroduce secrets or local tokens into tracked files.
- If you touch licensing or repo metadata again, remember the current GitHub API still shows the license as `Other`; if that matters, standardize the license presentation in a GitHub-recognizable way.
