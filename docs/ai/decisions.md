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

## 2026-03-30 - SimmerSmith has its own standard MCP server separate from Codex

- The Codex bridge and the SimmerSmith MCP server are separate concerns.
- `simmersmith` is the standard MCP surface for operating SimmerSmith app domains directly.
- The SimmerSmith MCP server should wrap the existing API/service layer so external AI clients act on the same business logic as the app.

## 2026-03-30 - The SimmerSmith MCP server supports stdio by default and optional Streamable HTTP with simple bearer auth

- `stdio` remains the default transport because it works cleanly with Codex and similar local MCP clients.
- The same server can also run over Streamable HTTP for operator/external-client use.
- Static bearer-token auth is acceptable for the initial operator-focused HTTP mode.
- This HTTP mode is for the SimmerSmith MCP server itself, not the Codex bridge and not the in-app Assistant runtime.

## 2026-03-30 - Direct-provider API keys may be set from iOS but remain server-side only

- The native app may send a new OpenAI or Anthropic API key to the backend for storage.
- The backend must never return the stored key value to the client; it only returns a secret-present flag.
- Clearing the stored key is an explicit destructive action from the client and is performed by sending an empty server-side secret value.

## 2026-03-30 - Direct-provider models are discovered from the provider and selected from iOS

- The iOS app should not ask the operator to type model IDs manually.
- The backend is responsible for discovering available models from the selected provider using the effective configured key.
- The chosen model is stored server-side as profile state and read back as normal non-secret settings.

## 2026-03-30 - After AI/MCP validation, the roadmap returns to import quality work

- The current AI/MCP/provider-model discovery slice is validated enough to stop blocking the recipe roadmap.
- The next active product phase is `Import quality lab`, followed by `Scan/photo/PDF import hardening`.
- Remaining AI/MCP items are follow-up hardening and operator decisions, not blockers for resuming recipe-platform work.

## 2026-03-30 - Recipe import UX and hardening is now the next active roadmap phase

- The current import UI buries camera/photo/PDF import under the `Import from URL` action, which is misleading.
- The next active phase should treat recipe import as one cohesive workflow covering discoverability, UX, fixtures, and parser hardening.
- Import UX and hardening now takes precedence over the next AI feature slice.

## 2026-03-30 - Recipe ingredients keep human text but now resolve to canonical ingredient identity

- Recipe, inline meal, and grocery ingredient rows should preserve their human-readable text fields for fidelity and editing.
- The app should attach canonical ingredient identity alongside that text using `base_ingredient_id`, optional `ingredient_variation_id`, and `resolution_status`.
- Grocery, nutrition, and preference logic should prefer canonical ingredient identity and only fall back to raw strings when no safe resolution exists.

## 2026-03-30 - Household ingredient preferences resolve groceries unless a recipe explicitly locks a product

- Structured ingredient preferences now live on canonical base ingredients instead of string-only brand or ingredient signals.
- Grocery resolution precedence is:
  1. locked recipe variation
  2. household preferred variation / brand
  3. resolved recipe variation
  4. base ingredient only
- This lets recipes stay generic while still turning grocery output into the right household-specific product choice.

## 2026-03-30 - Native import methods are first-class create actions and ingredient review starts as a per-row sheet

- URL, camera scan, photo import, and PDF import should be directly discoverable from the Recipes create menu instead of being hidden behind a misleading URL import entry point.
- The first native ingredient review UX is a per-ingredient sheet launched from the recipe editor, not a full bulk-review screen.
- The first sheet supports reviewing the suggested canonical ingredient, choosing a different base ingredient, selecting a stored variation, and optionally locking the recipe to that product.

## 2026-03-30 - Household ingredient preferences are first edited in Settings

- The first native UI for structured ingredient preferences lives in Settings, not in recipe review or grocery review flows.
- Preference editing is centralized around canonical base ingredients, optional stored variations, choice mode, optional preferred brand text, and active/inactive state.
- Recipe review and grocery review can link into the same preference system later, but the first slice keeps creation and editing in one stable operator-facing place.

## 2026-03-30 - Bulk ingredient review is centralized in a shared review queue and reuses existing editors

- The first bulk-review UX is a shared native queue reachable from both `Recipes` and `Grocery`.
- Recipe-side review items do not get a separate bespoke resolver screen; they route into the existing recipe editor so one canonical recipe-editing workflow remains the source of truth.
- Grocery-side review items can launch the same household ingredient preference editor when the grocery row already has enough canonical identity to make a household preference meaningful.

## 2026-03-31 - Recipe import regressions now live in a fixture corpus on disk

- Import regressions should be captured as files under `tests/fixtures/recipe_import` instead of only as inline strings inside test functions.
- The fixture corpus should cover URL imports, direct text imports, and OCR/PDF-style noisy text so parser and cleanup regressions can be reproduced from the repo alone.
- Real-world bug reports, such as the Burnt Ends ingredient parsing failure, should be preserved as durable regression fixtures when practical.

## 2026-03-31 - Ingredient review can create catalog entities in place

- Users should be able to create missing base ingredients and product variations directly from the native ingredient review sheet.
- Newly created catalog entities should be immediately selected back into the current ingredient-resolution workflow instead of forcing a second manual lookup.
- This keeps recipe import and cleanup momentum inside one editing flow and reduces the need to bounce into separate admin/catalog screens.

## 2026-03-31 - The web admin mirrors the recipe-level ingredient review flow first

- The first web ingredient-review slice should mirror the existing recipe-level workflow instead of introducing a separate catalog-management surface.
- Operators should be able to find review-needed recipes from the Recipes page and resolve ingredient matches inside the recipe editor.
- Grocery review on the web remains recipe-first for now; canonical ingredient corrections still happen in the source recipe editor rather than directly on grocery rows.

## 2026-03-31 - Direct-provider API keys are stored per provider, not as one shared secret

- OpenAI and Anthropic now have separate server-side profile secret keys.
- Switching providers should not require overwriting or re-entering the other provider's key.
- The client still only receives provider-specific secret-present flags; it must never read stored key values back.

## 2026-03-31 - Assistant bubbles need fallback text when a provider returns only a draft artifact

- Providers may legitimately return a recipe draft without companion markdown.
- The backend and iOS UI should both synthesize a short fallback message instead of rendering a visually blank assistant response.
- This keeps OpenAI and Anthropic turns aligned at the UI layer even when their structured outputs differ.

## 2026-03-31 - New import-time ingredient resolution may create immediate base ingredients to keep review searchable

- When import resolution cannot find an existing safe catalog match, the server may create a base ingredient immediately so the ingredient becomes searchable in preferences and review flows without a later reseed.
- This is a pragmatic bridge for the current catalog rollout, not the final branded-import policy.
- Follow-up work should refine how literal those auto-created base ingredient names are and when product variations should be suggested or locked.

## 2026-03-31 - Product work should focus on backend, iOS, and MCP; the web frontend is being decommissioned

- The user no longer wants the web frontend to be a supported product surface.
- New roadmap effort should prioritize backend API, iOS, and MCP workflows.
- The existing web frontend should only receive maintenance needed to keep the repo stable until decommissioning is handled deliberately.

## 2026-03-31 - Ingredient preferences need a browseable catalog, not search-only setup

- The first settings-only preference editor was too hidden and too dependent on guessing the right search text.
- Settings now includes a lightweight ingredient catalog browser so preference editing can start from real base ingredients already in the system.
- This is still a first step, not a full ingredient-management console; edit/merge/archive behavior is a follow-up decision.

## 2026-03-31 - Failed assistant turns must render as explicit errors, not blank bubbles

- If a provider turn fails after the user sends a message, the persisted assistant message should carry readable error text.
- The iOS assistant UI should render stored error text before falling back to an empty bubble.
- This is especially important for Anthropic troubleshooting, where schema-output failures otherwise look like blank assistant replies.

## 2026-04-01 - Ingredient management now lives in a dedicated native area, not only inside Settings search flows

- The app now has a dedicated native `Ingredients` management experience for browsing and maintaining canonical ingredient data.
- Ingredient management is reachable from both `Settings` and `Recipes`, but it is treated as a real product surface with detail/edit/merge/archive flows.
- Recipe text remains the source of truth for user-facing ingredient phrasing, while the `Ingredients` area manages canonical base ingredients and product variations behind that text.

## 2026-04-01 - Ingredient catalog seeding is source-aware and must fail gracefully under external API limits

- USDA FoodData Central and Open Food Facts are the initial external sources for generic calories and branded/package product data.
- The seed pipeline should continue running and report skipped requests when external APIs throttle or intermittently fail; transient third-party issues should not crash the entire ingest run.
- Production seeding strategy is still undecided, but the code path assumes source provenance and local SimmerSmith overrides are first-class.

## 2026-04-02 - USDA seed credentials are server-side config, not command-line-only inputs

- SimmerSmith now exposes a dedicated `SIMMERSMITH_USDA_API_KEY` server setting.
- The ingredient seed script prefers that server-side setting automatically and only falls back to `DEMO_KEY` if neither the CLI flag nor the env var is set.
- Docker also passes the USDA key through so local production-style runs and seed workflows can share the same configuration.

## 2026-04-02 - Live ingredient seeding should target the Docker-backed app database, not only temp local databases

- The first real operator seed should run inside the `simmersmith` container from `/workspace` so it uses the same migrations, config, and writable SQLite file as the live app.
- Temp local seed databases are still useful for smoke tests, but they are not enough to prove the live product catalog is populated.
- The first live USDA-backed seed worked, but the resulting corpus still needs review for search quality and noisy matches before treating it as the final default catalog experience.
