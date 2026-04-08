# SimmerSmith MCP Tools

This file documents the standard `simmersmith` MCP server for external AI clients.

## Purpose

The `simmersmith` MCP server exposes the same app domains the native client and backend use:

- recipes
- profile
- preferences
- weeks
- exports
- assistant threads
- health / AI capability status

It is intended to let external AI clients operate SimmerSmith directly instead of screen-scraping or inventing parallel state.

## How To Run

### Stdio

Use the wrapper script:

```bash
/Users/tfinklea/git/simmersmith/.venv/bin/python /Users/tfinklea/git/simmersmith/scripts/run_simmersmith_mcp.py
```

This is how the global Codex MCP entry named `simmersmith` is configured locally.

### Streamable HTTP

Use the same server with explicit transport:

```bash
/Users/tfinklea/git/simmersmith/.venv/bin/python /Users/tfinklea/git/simmersmith/scripts/run_simmersmith_mcp.py \
  --transport streamable-http \
  --host 127.0.0.1 \
  --port 8766 \
  --path /mcp \
  --bearer-token YOUR_TOKEN
```

When `--bearer-token` is provided, clients must send:

```http
Authorization: Bearer YOUR_TOKEN
```

## Highest-Value Tools

### Health and capability status

- `health`

Use this first to see whether the backend is healthy and whether AI is currently executable through direct providers or MCP.

### Recipes

- `recipes_list`
- `recipes_get`
- `recipes_save`
- `recipes_import_from_url`
- `recipes_import_from_text`
- `recipes_suggestion_draft`
- `recipes_companion_drafts`
- `recipes_variation_draft`

Recommended use:

- list recipes before generating suggestions or variations
- use import tools for URL/OCR flows
- keep AI recipe flows draft-first

### Profile and preferences

- `profile_get`
- `profile_update`
- `preferences_get`
- `preferences_upsert`
- `preferences_score_meal`

Recommended use:

- read profile and preference context before planning or recipe generation
- prefer updating signals/rules through these tools instead of editing raw DB state

### Weeks and planning

- `weeks_list`
- `weeks_get_current`
- `weeks_get`
- `weeks_create`
- `weeks_update_meals`
- `weeks_mark_ready_for_ai`
- `weeks_approve`
- `weeks_regenerate_grocery`
- `weeks_get_changes`
- `weeks_get_feedback`
- `weeks_save_feedback`
- `weeks_get_pricing`
- `weeks_import_pricing`

Recommended use:

- treat week edits as staged business logic, not ad hoc data mutation
- inspect changes/feedback instead of assuming current status

### Exports

- `weeks_list_exports`
- `weeks_create_export`
- `exports_get`
- `exports_get_apple_reminders`
- `exports_complete`

Recommended use:

- create exports from the week tool surface
- use export detail tools for follow-through and completion

### Assistant

- `assistant_list_threads`
- `assistant_create_thread`
- `assistant_get_thread`
- `assistant_archive_thread`
- `assistant_respond`

Recommended use:

- create a thread first
- use `assistant_respond` for conversational cooking help or draft recipe creation
- treat returned recipe drafts as drafts until explicitly saved with `recipes_save`

## Example Prompt Patterns

### Create a week and stage meals

1. `health`
2. `weeks_get_current`
3. `recipes_list`
4. `weeks_create`
5. `weeks_update_meals`
6. `weeks_regenerate_grocery`

This pattern is useful when an external client is acting like a planner:

- fetch current health first so the client knows whether AI execution is available
- inspect the current week before making changes
- pick recipes from the existing library rather than inventing new state
- stage meal changes before any approval or grocery regeneration step

### Create a week export and finish it

1. `weeks_get_current`
2. `weeks_get`
3. `weeks_create_export`
4. `exports_get`
5. `exports_get_apple_reminders`
6. `exports_complete`

This is the right shape for a client that needs to produce a shareable export:

- start from the current week or a specific week ID
- create the export from the week tool surface
- read the export payload before marking it complete
- use `exports_get_apple_reminders` when the destination is Apple Reminders

### Read and continue an assistant thread

1. `assistant_list_threads`
2. `assistant_create_thread`
3. `assistant_respond`
4. `assistant_get_thread`
5. `assistant_respond` again if the user wants a follow-up

This pattern is the safest way to keep assistant work coherent:

- create a thread before sending a new prompt
- inspect the returned thread state instead of assuming the model reply is the only source of truth
- treat recipe drafts returned by `assistant_respond` as drafts until explicitly saved with `recipes_save`

### Import a recipe and save it

1. `recipes_import_from_url`
2. inspect the returned draft
3. optionally `recipes_nutrition_estimate`
4. `recipes_save`

### Use the assistant to draft a recipe

1. `assistant_create_thread`
2. `assistant_respond` with `intent="recipe_creation"`
3. inspect `assistant_message.recipe_draft`
4. `recipes_save` only if the user wants to keep it

### Minimal recipe-edit loop

1. `recipes_list`
2. `recipes_get`
3. `recipes_save`

Use this when the client already knows the recipe is the right starting point and only needs to inspect or persist an edit. For external clients, the safer default is still to list first, inspect second, and save only after the user confirms the draft.

## Guardrails

- Do not silently persist AI-generated recipes.
- Do not mutate weeks or groceries without using the week/export tools.
- Prefer reading current profile, preferences, and health first for non-trivial flows.
- The MCP server is a control surface for SimmerSmith, not a replacement for the server’s business rules.
