# Current State

## Active Branch

- `main`

## Recent Progress

- Added a real standard SimmerSmith MCP server with repo-backed tools for recipes, profile, preferences, weeks, exports, and assistant threads.
- Added a stable wrapper script so Codex and other MCP clients can launch the SimmerSmith MCP server from anywhere.
- Registered the standard MCP server in Codex as `simmersmith` and removed the misleading `codex-local` entry.
- Replaced the Assistant's local `codex exec` fallback with two real execution paths:
  - direct OpenAI / Anthropic APIs when configured
  - remote MCP over Streamable HTTP when direct keys are absent
- Added a local development MCP bridge script that exposes `codex mcp-server` over Streamable HTTP without changing the app's runtime contract.
- Verified the backend against the local MCP bridge with no saved API keys:
  - health now reports MCP as available and selected as the default target
  - a general assistant turn (`Hi`) succeeds end to end
  - a recipe-creation turn returns a draft recipe artifact end to end
- Added MCP server configuration for the backend, including URL, auth token, and Codex tool names.
- Added a real MCP client adapter and runtime probe so health/capability reporting reflects whether the configured MCP server is actually reachable and exposes the expected Codex tools.
- Persisted the external MCP thread ID on assistant threads so subsequent turns continue with `codex-reply` instead of starting a fresh conversation every time.
- Updated the iOS Assistant and Settings surfaces so AI remains visible, but chat creation/send is disabled with setup guidance when neither direct providers nor MCP are executable.
- Kept the older heuristic recipe AI actions in place for now.

## Recent Commits

- `011a591` `feat: add local codex mcp bridge`
- `42b9016` `fix: recover assistant chat after stream decode errors`
- `00249fa` `fix: repair assistant codex fallback stream`
- `75b8040` `feat: add central assistant chat workflow`
- `787ccf2` `feat: add recipe companion suggestion drafts`

## Changed Files In The Current Slice

- `app/mcp_server.py`
- `scripts/run_simmersmith_mcp.py`
- `docs/ai/roadmap.md`
- `docs/ai/current-state.md`
- `docs/ai/next-steps.md`
- `docs/ai/decisions.md`

## Working Tree

- dirty with the standard SimmerSmith MCP server slice until the current commit is created

## Blockers

- none in code
- the local MCP bridge currently emits noisy `codex/event` validation logs from the upstream MCP SDK during tool execution, but calls still complete successfully

## Open Questions

- Should the existing heuristic suggestion / companion / variation routes migrate onto the same direct/MCP execution layer next, or stay lightweight until after import hardening?
- Do we want a user-facing server settings surface for MCP configuration later, or keep MCP transport config server-side only?
- Should the local bridge remain a dev-only helper script, or become a documented operator option for laptop-hosted MCP setups?
- Which external AI clients do we want to optimize first for the new standard SimmerSmith MCP surface beyond Codex?

## Validation / Test Status

Latest completed validation for the direct/MCP execution refactor:

- `python3 -m compileall app tests alembic` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`23 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the local MCP bridge slice:

- `.venv/bin/python -m py_compile scripts/codex_mcp_http_bridge.py app/services/mcp_client.py` -> passed
- local MCP probe via `run_codex_mcp(...)` against `http://127.0.0.1:8765/mcp` -> passed
- `GET /api/health` with `SIMMERSMITH_AI_MCP_BASE_URL=http://127.0.0.1:8765/mcp` -> MCP available and default target is `mcp`
- end-to-end assistant thread create/respond (`Hi`) over the live API with no direct-provider keys -> passed
- end-to-end assistant recipe creation turn over the live API with no direct-provider keys -> passed with `assistant.recipe_draft`

Latest completed validation for the standard SimmerSmith MCP server slice:

- `.venv/bin/python -m py_compile app/mcp_server.py scripts/run_simmersmith_mcp.py` -> passed
- stdio MCP smoke test via the Python MCP client -> passed
- tool listing returned 47 SimmerSmith tools
- MCP `health` tool call -> passed
- Codex global MCP registration now shows `simmersmith` as an enabled stdio MCP server

## Runtime Notes

- The local backend is typically run on `http://localhost:8080`.
- Bearer token used in local testing: `2cc40b9addb61756ac8ab7e4405cab696ff68f8e8fe084c8`
- MCP execution now expects a remote Streamable HTTP MCP server configured via server settings / env vars.
- For local laptop development, `scripts/codex_mcp_http_bridge.py` can provide a Streamable HTTP MCP endpoint at `http://127.0.0.1:8765/mcp` backed by `codex mcp-server`.
- For external AI control of the app itself, `scripts/run_simmersmith_mcp.py` launches the standard SimmerSmith MCP server.
- Codex is now configured with a global MCP entry named `simmersmith` that launches the repo MCP server over stdio.
- The backend should no longer rely on local `codex exec` for Assistant turns.
