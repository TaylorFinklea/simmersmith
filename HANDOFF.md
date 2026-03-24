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

This is the next major execution track.

### 1. Recipe scan import

Not done yet.

Needed:

- import recipe from camera/image/PDF
- route it through the same normalization pipeline as URL import
- open as editable draft before save

Why it matters:

- this is a core Apple-first capture behavior
- it belongs naturally in iPhone usage

### 2. AI recipe suggestions and AI recipe variations

Not done yet.

Needed:

- AI suggestion drafts based on the user’s saved recipes and internet context
- AI variation drafts for ingredient swaps, dietary alternatives, and similar transforms
- all AI outputs should arrive as drafts, never silently saved

Important architecture requirement:

- AI should be MCP-first
- but the server should be architected for future direct API-key provider support
- do not hardcode an MCP-only contract if you touch AI surfaces

### 3. Recipe PDF export and customizable template system

Not done yet.

Needed:

- native iOS PDF export/share
- recipe export templates
- customizable layout/presentation
- eventually align all recipes to a reusable template model

### 4. Recipe experience polish

Still likely needed even after the above:

- ensure “last used” / “time since last used” are surfaced clearly and sort behavior feels useful
- make breakfast and dinner the most ergonomic discovery flows
- make variant selection/creation friction very low
- stress-test import quality on real recipe sites
- review whether the cuisine/tag/unit managed-list UX feels native enough

## Next after Recipes: future-week planning wizard

This should not start until Recipes feel trustworthy.

Desired wizard direction:

- choose a future week
- browse/select recipes first
- emphasize dinner and breakfast
- lunch remains supported but secondary
- assign selected recipes into slots
- leave intentional gaps
- hand partial plan to AI afterward for collaboration/fill-in

The current codebase already has some week assignment plumbing, but not the full guided wizard.

## Longer-Term Roadmap After That

These are still part of the broader product direction, but they are not the immediate next build order:

1. AI planning collaboration
   - week-level and slot-level assist
   - fill gaps after human picks recipes

2. Grocery workspace maturation
   - editable grocery workspace
   - manual and derived items together
   - pricing invalidation behavior after edits

3. Pricing/store split/cart prep quality
   - better trustworthiness and handoff quality

4. Equipment intelligence
   - household equipment inventory
   - timing estimates and conversion suggestions based on actual owned equipment

5. macOS operator client
   - after server contracts and iOS information architecture are stable

## Suggested Next Session Execution Order

1. Read this file.
2. Inspect and resolve the dirty `project.pbxproj` diff.
3. Confirm the repo still builds in its renamed location.
4. Choose the next recipe slice:
   - recommended next: recipe scan import
5. After scan import, do:
   - AI recipe suggestions / variation drafts
6. Then:
   - recipe PDF/template export
7. Only then:
   - guided future-week planning wizard

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
