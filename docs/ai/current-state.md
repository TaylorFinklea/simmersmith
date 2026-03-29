# Current State

## Active Branch

- `main`

## Recent Progress

- Replaced the Assistant's local `codex exec` fallback with two real execution paths:
  - direct OpenAI / Anthropic APIs when configured
  - remote MCP over Streamable HTTP when direct keys are absent
- Added MCP server configuration for the backend, including URL, auth token, and Codex tool names.
- Added a real MCP client adapter and runtime probe so health/capability reporting reflects whether the configured MCP server is actually reachable and exposes the expected Codex tools.
- Persisted the external MCP thread ID on assistant threads so subsequent turns continue with `codex-reply` instead of starting a fresh conversation every time.
- Updated the iOS Assistant and Settings surfaces so AI remains visible, but chat creation/send is disabled with setup guidance when neither direct providers nor MCP are executable.
- Kept the older heuristic recipe AI actions in place for now.

## Recent Commits

- `42b9016` `fix: recover assistant chat after stream decode errors`
- `00249fa` `fix: repair assistant codex fallback stream`
- `75b8040` `feat: add central assistant chat workflow`
- `787ccf2` `feat: add recipe companion suggestion drafts`
- `673b7c8` `docs: add shared ai handoff workflow`

## Changed Files In The Current Slice

- `pyproject.toml`
- `app/config.py`
- `app/main.py`
- `app/models.py`
- `app/api/assistant.py`
- `app/services/ai.py`
- `app/services/assistant_ai.py`
- `app/services/mcp_client.py`
- `alembic/versions/20260329_0011_assistant_provider_thread.py`
- `tests/test_api.py`
- `SimmerSmith/SimmerSmith/App/AppState.swift`
- `SimmerSmith/SimmerSmith/Features/Assistant/AssistantView.swift`
- `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift`
- `docs/ai/roadmap.md`
- `docs/ai/current-state.md`
- `docs/ai/next-steps.md`
- `docs/ai/decisions.md`

## Working Tree

- dirty with the direct-provider + MCP execution refactor until the current commit is created

## Blockers

- none in code
- manual end-to-end validation still depends on a real remote MCP endpoint being configured on the backend if API keys are not present

## Open Questions

- Should the existing heuristic suggestion / companion / variation routes migrate onto the same direct/MCP execution layer next, or stay lightweight until after import hardening?
- Do we want a user-facing server settings surface for MCP configuration later, or keep MCP transport config server-side only?

## Validation / Test Status

Latest completed validation for the direct/MCP execution refactor:

- `python3 -m compileall app tests alembic` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`23 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

## Runtime Notes

- The local backend is typically run on `http://localhost:8080`.
- Bearer token used in local testing: `2cc40b9addb61756ac8ab7e4405cab696ff68f8e8fe084c8`
- MCP execution now expects a remote Streamable HTTP MCP server configured via server settings / env vars.
- The backend should no longer rely on local `codex exec` for Assistant turns.
