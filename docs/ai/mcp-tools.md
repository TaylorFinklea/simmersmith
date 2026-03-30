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

## Guardrails

- Do not silently persist AI-generated recipes.
- Do not mutate weeks or groceries without using the week/export tools.
- Prefer reading current profile, preferences, and health first for non-trivial flows.
- The MCP server is a control surface for SimmerSmith, not a replacement for the server’s business rules.
