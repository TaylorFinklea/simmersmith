# Current State

## Active Branch

- `main`

## Recent Progress

- Implemented phase 1: AI recipe suggestion drafts.
- Added a server route for draft-only recipe suggestions grounded in the saved recipe library.
- Added an iOS entry point in the Recipes screen to open AI suggestion drafts in the existing editor.
- Expanded the roadmap in `HANDOFF.md` to reflect recipe work, sprinkled tech debt, and Cloudflare/web platform tracks.
- Added shared `docs/ai` handoff docs plus repo-level `AGENTS.md` and `CLAUDE.md` so assistants use the same repo-based workflow.

## Recent Commits

- `00db9e9` `feat: add AI recipe suggestion drafts`
- `1cec868` `docs: expand roadmap with platform tech debt`

## Changed Files In The Last Completed Slice

- `app/api/recipes.py`
- `app/schemas.py`
- `app/services/recipe_ai.py`
- `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift`
- `SimmerSmith/SimmerSmith/App/AppState.swift`
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipeSupport.swift`
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipesView.swift`
- `tests/test_api.py`
- `AGENTS.md`
- `CLAUDE.md`
- `docs/ai/roadmap.md`
- `docs/ai/current-state.md`
- `docs/ai/next-steps.md`
- `docs/ai/decisions.md`
- `docs/ai/handoff-template.md`

## Working Tree

- dirty until the current docs-work commit is created

## Blockers

- none currently

## Open Questions

- How opinionated should recipe companion suggestions be versus recipe suggestions?
- When recipe suggestions move beyond the current heuristic/library-grounded implementation, what internet-context inputs should be allowed server-side first?

## Validation / Test Status

Latest completed validation for the AI recipe suggestion draft slice:

- `.venv/bin/pytest tests/test_api.py -q` -> passed
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Docs workflow slice:

- file creation/update only
- no additional build/test run yet after the docs-only changes

## Runtime Notes

- The local backend is typically run on `http://localhost:8080`.
- Bearer token used in local testing: `2cc40b9addb61756ac8ab7e4405cab696ff68f8e8fe084c8`
- Do not assume the backend is running; verify before testing.
