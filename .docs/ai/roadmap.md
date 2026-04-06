# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

SimmerSmith is an AI-first meal planning app for the App Store. AI is the star — it plans your week, optimizes your grocery list, and makes every part of meal planning easier. iOS is the primary client, FastAPI + Supabase is the canonical backend, and self-hosting is a first-class option.

## Milestones

### M0: Foundation & Audit (2-3 weeks)
Get the codebase onto solid ground. Full code audit first — Codex-generated code is untrusted.

- [ ] Code quality audit — full review of backend services, iOS views, SimmerSmithKit
- [ ] Kill web frontend — remove `frontend/`, Vite config, SPA routing, simplify Dockerfile
- [ ] Database abstraction — validate SQLAlchemy on both SQLite and Postgres, dialect-aware migrations
- [ ] Supabase project setup — Postgres instance, auth configuration
- [ ] Multi-user data isolation — add `user_id` to all relevant tables, auth middleware in FastAPI
- [ ] Supabase Auth integration — JWT validation in FastAPI, iOS auth flow
- [ ] TestFlight pipeline — unblock upload (ASC API key or repair credentials)

### M1: AI-Driven Core Experience (3-4 weeks)
Build the product that makes AI the star.

- [ ] Guided onboarding — full AI preference interview (household size, dietary restrictions, allergies, cuisine prefs, budget, cooking skill, time, equipment, store preferences)
- [ ] AI-driven week planning wizard — "tell it what you want, it builds a full week"
- [ ] Recipe import quality hardening (partially done — critical for launch)
- [ ] Recipe editor polish — PDF export, live step/substep reorder, template customization
- [ ] Product-like catalog rewrite — review and apply to live DB

### M2: Grocery & Pricing (2-3 weeks)
Complete the meal-to-purchase pipeline.

- [ ] Grocery list generation from canonical ingredients (partially exists)
- [ ] Store-specific pricing — hybrid model (API/scraping + user-reported corrections)
- [ ] AI-optimized grocery suggestions (substitutions, deals, cheapest store)
- [ ] Retailer matching via canonical ingredient identity (currently raw strings)

### M3: Polish & Launch (2-3 weeks)
Ship it.

- [ ] iOS App Store quality polish — error states, loading states, empty states, accessibility
- [ ] Push notifications — meal reminders, grocery day, plan ready
- [ ] Basic analytics — usage tracking, feature adoption, meal planning patterns
- [ ] MCP surface with user-scoped access (currently single-user)
- [ ] Self-hosted Docker documentation and setup
- [ ] App Store submission (metadata, screenshots, review prep)
- [ ] Performance and edge case hardening

### M4: Post-Launch
- [ ] Household sharing (designed for at launch, shipped after)
- [ ] Freemium boundaries (once usage data exists)
- [ ] Advanced analytics — nutrition trends, budget tracking, cooking patterns over time
- [ ] macOS operator client
- [ ] Advanced AI features (meal prep optimization, nutrition tracking, dietary goal progress)

## Backlog (parallel, tiered by model capability)

<!-- tier3_owner: claude -->

### Haiku (mechanical, no judgment)
- [x] Remove web frontend files and all references — `frontend/`, `vite.config.ts`, SPA fallback in `app/main.py`
- [x] Update Docker config after web removal — `Dockerfile`, `docker-compose.yml`
- [x] Add `.gitignore` entries for Supabase local dev files
- [~] Fix 4 bare `except Exception:` blocks — add structured logging instead of silently swallowing — `app/db.py:34,56`, `app/services/assistant_threads.py:100`, `app/services/mcp_client.py:64`
- [ ] Replace `print()` calls with `logging` in library code — `app/services/ingredient_ingest.py:331,393`
- [ ] Extract magic numbers to named constants — `app/services/ingredient_catalog.py:522` (MAX_LINKED_ITEMS=20), `app/services/assistant_threads.py:89,102` (title/preview char limits)
- [ ] Add `# type: ignore` justification comment — `app/config.py:38`
- [ ] Add return type hints to recipe route handlers — `app/api/recipes.py:49,96,117,138,156,177,192,206,219,235`
- [ ] Add return type hints to ingredient route handlers — `app/api/ingredients.py` (10 functions)
- [ ] Add return type hints to AI draft service functions — `app/services/recipe_ai.py:606,647,747,777,839`, `app/services/drafts.py:87`, `app/mcp_server.py:128`

### Sonnet (some architectural judgment)
- [ ] Expand Swift Testing coverage across all feature areas — `SimmerSmithKit/`
- [ ] Add UI automation smoke tests for core iOS flows — `SimmerSmith/`
- [ ] Split `app/services/ingredient_catalog.py` (1,495 lines) — extract search, product-rewrite, and variation modules
- [ ] Split `app/services/recipe_import.py` (1,040 lines) — extract parser and ingredient normalizer
- [ ] Split `app/mcp_server.py` (835 lines) — extract per-domain route modules (recipes, ingredients, weeks, etc.)
- [ ] Split `app/models.py` (723 lines) — extract domain-specific model files (recipe, ingredient, week, ai)
- [ ] Split `app/schemas.py` (711 lines) — extract domain-specific schema files to match models split
- [ ] Decompose `SimmerSmith/SimmerSmith/Features/Recipes/RecipeEditorView.swift` (1,479 lines) — extract IngredientResolutionSheet, StepsEditor, NutritionEditor sub-views
- [ ] Decompose `SimmerSmith/SimmerSmith/Features/Ingredients/IngredientsView.swift` (975 lines) — extract CatalogList, VariationManagement, MergeSheet sub-views
- [ ] Decompose `SimmerSmith/SimmerSmith/App/AppState.swift` (1,119 lines) — split into domain-specific state modules (Recipes, Weeks, Assistant, AI)

### Opus (design skill, cross-cutting — owned by tier3_owner)
- [ ] Design the AI preference interview conversation flow
- [ ] Design the week planning wizard UX and AI integration
- [ ] Design multi-user data isolation strategy (user_id on tables, row-level security)
- [ ] Design the freemium gate architecture (for later activation)

## Priority Order

M0 → M1 → M2 → M3 → M4. Backlog runs alongside any milestone.

## Constraints

- AI is the primary interaction model, not a side feature.
- Do not silently persist AI-generated recipes or week changes.
- Support both SQLite (self-hosted) and Postgres (Supabase cloud).
- Single-user accounts at launch; design for household sharing post-launch.
- Self-hosting is a first-class option, not an afterthought.
- MCP/agent access is a launch differentiator.
- Freemium AI boundaries TBD — build the product first, add gates later.
- Do not spend new effort on the web frontend — it is being removed.
- Keep shared docs updated at session end.

## Open Decisions

Record in `.docs/ai/decisions.md` as resolved:

1. Supabase Auth — which social providers at launch? (Apple + email? Google?)
2. AI provider for freemium tier — which model for free users vs. paid?
3. Pricing data source — which grocery APIs? (Instacart, store-specific, etc.)
4. MCP auth for multi-user — how does MCP access work with Supabase Auth tokens?
5. Self-hosted auth — Supabase Auth or local bearer tokens?
6. Push notification service — APNs direct, or through a service?
7. Analytics provider — Supabase analytics, PostHog, Mixpanel, or custom?
