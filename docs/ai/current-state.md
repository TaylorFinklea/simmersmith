# Current State

## Active Branch

- `main`

## Recent Progress

- Confirmed the current iOS import information architecture is misleading:
  - `Recipes` -> `Create` -> `Import from URL` opens the shared import sheet
  - that sheet also contains camera scan, photo import, and PDF import actions
- Re-prioritized the roadmap so recipe import UX and hardening is now the next active phase.
- Completed the AI/MCP validation pass and confirmed the live backend is healthy on the local token-protected server.
- Verified the Assistant works end to end with the direct-provider path using the saved OpenAI key:
  - `general` turns stream cleanly
  - `recipe_creation` turns return a draft recipe artifact and do not auto-save
- Verified provider-backed model discovery against the live backend:
  - OpenAI model discovery returns a populated list
  - the currently selected saved model resolves as `gpt-5.4-mini`
- Verified the standard `simmersmith` MCP server from an external Codex session:
  - `health` works
  - recipe listing works
- Re-verified the Streamable HTTP mode for the standard `simmersmith` MCP server with bearer-token auth.
- The roadmap is now ready to move back to the next product phase: `Import quality lab`.
- Added provider-backed model discovery for OpenAI and Anthropic so the iOS app can present a model picker instead of a freeform text field.
- The native Settings screen now fetches available models for the selected direct provider from the backend and saves the chosen model server-side.
- Direct-provider model selection is now resolved from server-side profile settings first, then environment defaults.
- Added iOS Settings support for server-side-only AI direct-provider key management.
- The app can now set or clear a stored direct-provider API key on the server without ever reading the key value back into the client.
- Exposed profile update wiring in `SimmerSmithKit` so the native app can update AI provider mode, direct provider selection, and the stored secret-presence state safely.
- Added a real standard SimmerSmith MCP server with repo-backed tools for recipes, profile, preferences, weeks, exports, and assistant threads.
- Added a stable wrapper script so Codex and other MCP clients can launch the SimmerSmith MCP server from anywhere.
- Registered the standard MCP server in Codex as `simmersmith` and removed the misleading `codex-local` entry.
- Added optional Streamable HTTP transport for the standard SimmerSmith MCP server, including simple static bearer-token auth for operator use.
- Added `docs/ai/mcp-tools.md` to document the SimmerSmith MCP surface, launch modes, auth, and recommended tool usage patterns.
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

- `e40d4e1` `feat: add provider model discovery`
- `0b4a8fd` `feat: add server-side ai key settings`
- `e15eaa0` `feat: add http mode for simmersmith mcp`
- `7671198` `feat: add simmersmith mcp server`
- `011a591` `feat: add local codex mcp bridge`
- `42b9016` `fix: recover assistant chat after stream decode errors`
- `00249fa` `fix: repair assistant codex fallback stream`
- `75b8040` `feat: add central assistant chat workflow`
- `787ccf2` `feat: add recipe companion suggestion drafts`

## Changed Files In The Current Slice

- `docs/ai/current-state.md`
- `docs/ai/next-steps.md`
- `docs/ai/decisions.md`

## Working Tree

- clean before the docs closeout for this validation pass

## Blockers

- none in code
- the local MCP bridge currently emits noisy `codex/event` validation logs from the upstream MCP SDK during tool execution, but calls still complete successfully

## Open Questions

- What should the top-level Recipes create/import IA be: separate import actions, a dedicated import hub, or a renamed create/import sheet?
- Should the existing heuristic suggestion / companion / variation routes migrate onto the same direct/MCP execution layer next, or stay lightweight until after import hardening?
- Do we want a user-facing server settings surface for MCP configuration later, or keep MCP transport config server-side only?
- Should the local bridge remain a dev-only helper script, or become a documented operator option for laptop-hosted MCP setups?
- Which external AI clients do we want to optimize first for the new standard SimmerSmith MCP surface beyond Codex?
- Do we want to keep static bearer-token auth as the only HTTP auth mode for now, or add a more formal auth story before recommending network exposure?
- Should server-side AI key management remain in the general Settings form, or move to a dedicated AI configuration screen once more provider controls exist?
- Should we filter the discovered OpenAI model list more aggressively to only reasoning/chat models we explicitly support, or keep the broader provider-visible list?

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

Latest completed validation for the SimmerSmith MCP HTTP/auth slice:

- `.venv/bin/python -m py_compile app/mcp_server.py` -> passed
- `scripts/run_simmersmith_mcp.py --transport streamable-http --host 127.0.0.1 --port 8766 --path /mcp --bearer-token test-token` -> server started successfully
- authenticated `curl` to `http://127.0.0.1:8766/mcp` with `Authorization: Bearer test-token` -> reached MCP server and returned protocol-level response
- authenticated Python MCP client via `streamable_http_client(...)` -> initialized successfully
- HTTP MCP tool listing returned 47 SimmerSmith tools
- HTTP MCP `health` tool call -> passed

Latest completed validation for the iOS AI key settings slice:

- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the provider model discovery slice:

- `python3 -m compileall app tests` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`24 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the AI/MCP closeout pass:

- `GET /api/health` -> passed
- `GET /api/ai/providers/openai/models` -> passed, selected model `gpt-5.4-mini`, discovered models returned
- live Assistant `general` turn over the API with the current OpenAI key -> passed
- live Assistant `recipe_creation` turn over the API with the current OpenAI key -> passed with `assistant.recipe_draft`
- `codex exec` using the stdio `simmersmith` MCP server -> passed (`health` + recipe listing)
- `scripts/run_simmersmith_mcp.py --transport streamable-http ... --bearer-token test-token` + HTTP initialize request -> passed
- `python3 -m compileall app tests alembic` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`24 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

## Runtime Notes

- The local backend is typically run on `http://localhost:8080`.
- Bearer token used in local testing: `2cc40b9addb61756ac8ab7e4405cab696ff68f8e8fe084c8`
- MCP execution now expects a remote Streamable HTTP MCP server configured via server settings / env vars.
- For local laptop development, `scripts/codex_mcp_http_bridge.py` can provide a Streamable HTTP MCP endpoint at `http://127.0.0.1:8765/mcp` backed by `codex mcp-server`.
- For external AI control of the app itself, `scripts/run_simmersmith_mcp.py` launches the standard SimmerSmith MCP server.
- Codex is now configured with a global MCP entry named `simmersmith` that launches the repo MCP server over stdio.
- The SimmerSmith MCP server can also be run over Streamable HTTP with optional static bearer auth by passing `--transport streamable-http --bearer-token ...`.
- The backend should no longer rely on local `codex exec` for Assistant turns.
- The iOS app now lets the operator set or clear a direct-provider API key, but the key itself is only stored server-side and is never returned in profile payloads.
- The iOS app now fetches the available model list for the selected direct provider from the backend and stores the chosen model server-side as profile state.
