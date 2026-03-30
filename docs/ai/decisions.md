# Decisions

This is a concise running ADR log. Add a new entry when a decision changes implementation direction, constraints, or sequencing.

## 2026-03-27 - Shared repo docs are the assistant handoff source of truth

- `docs/ai/roadmap.md`, `docs/ai/current-state.md`, and `docs/ai/next-steps.md` are the required session-start files.
- `docs/ai/current-state.md`, `docs/ai/next-steps.md`, and `docs/ai/decisions.md` are the required session-end update files.
- Chat memory is not the source of truth.

## 2026-03-27 - AGENTS.md and CLAUDE.md follow the shared docs workflow

- Repo-level `AGENTS.md` and `CLAUDE.md` are aligned around the same `docs/ai` session-start and session-end workflow.
- Assistant-specific guidance stays in those files, but shared state must live in `docs/ai/*`.

## 2026-03-27 - Phase 1 AI recipe suggestions ship as draft-only and library-grounded first

- The first implementation of recipe suggestions is heuristic and grounded in saved recipes plus existing metadata.
- Suggestions open in the existing recipe editor as drafts and are never silently saved.
- This preserves the current MCP-first architecture while keeping the first slice small and testable.

## 2026-03-27 - Phase 2 companion suggestions are recipe-detail-only and return three standalone drafts

- Companion suggestions currently live only on the recipe detail screen, not the recipes list.
- The server returns exactly three draft options per request: a vegetable side, a starch side, and a sauce/drizzle.
- Companion results are standalone recipe drafts, not variants, and are never auto-saved.
- The first implementation is deterministic and cuisine-aware, matching the existing MCP-first but heuristic-first rollout style.

## 2026-03-28 - Assistant is now a first-class tab with server-side threads

- The main tab bar now prioritizes `Assistant` as a primary feature surface.
- `Activity` is preserved but moved under `Week` instead of staying in the main tab bar.
- Assistant conversations are stored on the server in persistent thread/message tables so they survive app relaunch and can be shared across clients connected to the same backend.

## 2026-03-28 - Conversational AI uses direct providers first, then remote MCP

- Assistant turns prefer direct provider APIs when configured.
- If direct provider keys are absent, the server falls back to a real remote MCP execution path instead of invoking `codex` locally.
- Assistant responses use a structured envelope with markdown plus an optional recipe draft artifact.

## 2026-03-28 - Assistant remains draft-only in v1

- The Assistant may answer cooking questions or return one recipe draft per turn.
- Assistant turns must not silently save recipes, mutate weeks, or change groceries in v1.
- Recipe detail and editor shortcuts launch into the centralized Assistant experience rather than creating separate one-off AI UIs.

## 2026-03-28 - Assistant SSE payloads and structured AI envelopes must be iOS-safe and strict

- Assistant SSE events should be JSON-encoded with API-style datetime serialization, not Python `str(datetime)` output.
- The structured assistant envelope schema should keep object payloads strict so both direct-provider and MCP-backed responses are validated before they reach the client.

## 2026-03-29 - Assistant streaming should recover from non-fatal decode drift

- If an assistant turn completes on the server but one SSE event fails to decode on iOS, the client should reload the final thread state and continue instead of surfacing a hard failure immediately.
- This keeps the Assistant usable while server/client event payloads evolve and makes final persisted thread state the fallback source of truth.

## 2026-03-29 - MCP execution is remote Streamable HTTP and persists provider thread IDs

- SimmerSmith should not launch local Codex processes for Assistant turns.
- MCP-backed Assistant execution connects to a user-managed remote MCP server over Streamable HTTP.
- Assistant threads persist the external provider thread ID so Codex-backed conversations continue with `codex-reply` instead of restarting every turn.

## 2026-03-30 - Local laptop MCP testing uses an explicit HTTP bridge, not app-owned Codex execution

- The app runtime still supports only direct providers or MCP over Streamable HTTP.
- For local development, a small helper bridge can expose `codex mcp-server` over Streamable HTTP so the backend can exercise the MCP path without saved provider keys.
- This bridge is a developer/operator tool, not a return to local `codex exec` fallback inside the app server.
