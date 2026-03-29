# Current State

## Active Branch

- `main`

## Recent Progress

- Implemented phase 1: AI recipe suggestion drafts.
- Added a server route for draft-only recipe suggestions grounded in the saved recipe library.
- Added an iOS entry point in the Recipes screen to open AI suggestion drafts in the existing editor.
- Implemented phase 2: recipe companion suggestions from recipe detail.
- Added a server route that returns exactly three standalone companion drafts for a selected recipe: vegetable side, starch side, and sauce/drizzle.
- Added an iOS recipe-detail action that opens a picker sheet for companion drafts, then hands the chosen draft to the existing recipe editor.
- Implemented phase 3: a first-class Assistant tab with persistent server-side threads and conversational recipe creation/refinement.
- Added server-side assistant thread/message storage, assistant APIs, and SSE-based assistant responses.
- Added provider execution with direct-provider support first and automatic server-side `codex` CLI fallback when provider API keys are absent.
- Moved `Activity` out of the main tab bar and under `Week` so `Assistant` can be a primary tab.
- Fixed two codex-path issues discovered during device testing: SSE timestamps now serialize in an iOS-decodable JSON format, and the generated `codex` JSON schema is now strict enough for `codex exec` to accept.
- Added iOS-side recovery in the Assistant chat flow: if one streamed event fails to decode, the app now reloads the final thread from the server instead of failing the whole turn immediately.
- Expanded the roadmap in `HANDOFF.md` to reflect recipe work, sprinkled tech debt, and Cloudflare/web platform tracks.
- Added shared `docs/ai` handoff docs plus repo-level `AGENTS.md` and `CLAUDE.md` so assistants use the same repo-based workflow.

## Recent Commits

- `00249fa` `fix: repair assistant codex fallback stream`
- `75b8040` `feat: add central assistant chat workflow`
- pending local commit for Assistant client-side stream recovery
- `00db9e9` `feat: add AI recipe suggestion drafts`
- `673b7c8` `docs: add shared ai handoff workflow`

## Changed Files In The Last Completed Slice

- `SimmerSmith/SimmerSmith/App/AppState.swift`
- `docs/ai/current-state.md`
- `docs/ai/next-steps.md`
- `docs/ai/decisions.md`

## Working Tree

- dirty with the Assistant codex-fallback / SSE-format repair until the current commit is created

## Blockers

- none currently, but local backend still needs a restart after the assistant changes before mobile testing

## Open Questions

- Should the older heuristic AI entry points eventually route through the new assistant orchestration layer, or remain separate lightweight APIs?
- How much of the assistant experience should be available from recipe detail/editor shortcuts versus kept centralized in the Assistant tab?
- Is true token-by-token provider streaming worth adding next, or is the current chunked SSE good enough for v1 testing?

## Validation / Test Status

Latest completed validation for the Assistant slice:

- `python3 -m compileall app tests alembic` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`21 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the codex-fallback repair:

- live manual API reproduction via `curl` on `/api/assistant/threads/{thread_id}/respond` -> passed on the `codex` fallback path with a recipe draft artifact
- `python3 -m compileall app tests` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`23 passed`)

Latest completed validation for the Assistant client recovery change:

- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

## Runtime Notes

- The local backend is typically run on `http://localhost:8080`.
- Bearer token used in local testing: `2cc40b9addb61756ac8ab7e4405cab696ff68f8e8fe084c8`
- Do not assume the backend is running; verify before testing.
- The backend is currently running with the assistant routes live and codex fallback verified.
