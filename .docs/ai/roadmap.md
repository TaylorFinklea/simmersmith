# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

SimmerSmith is an AI-first meal planning app for the App Store. AI is the star — it plans your week, optimizes your grocery list, and makes every part of meal planning easier. iOS is the primary client, FastAPI on Fly.io with Postgres is the backend.

**Design direction**: opinionated editorial (Paprika/Mela aesthetic) with AI as a central, prominent feature. Week, Recipes, and Assistant are the three core surfaces.

## Infrastructure (complete)

- [x] Backend deployed on Fly.io + Fly Postgres
- [x] Apple/Google auth endpoints (POST /api/auth/apple, /api/auth/google)
- [x] Multi-user data isolation (user_id on all user-owned tables, scoped queries, 7 isolation tests)
- [x] Session JWT issuance + legacy bearer fallback
- [x] Code quality audit + security hardening
- [x] Backend module decomposition (models, schemas, MCP, services all split)
- [x] iOS view decomposition (RecipeEditor, IngredientsView, AppState all split)

## R1: Core Flows (make it actually work end-to-end)

### R1.1 — Sign in with Apple (iOS)
- [ ] Wire ASAuthorizationAppleIDProvider → POST /api/auth/apple → store session JWT in Keychain
- [ ] New SignInView replacing ConnectionSetupView as primary onboarding
- [ ] Keep developer mode toggle in Settings for self-hosted/bearer connections

### R1.2 — AI week planning (end-to-end)
- [ ] Set AI provider key on Fly (OpenAI or Anthropic)
- [ ] Verify draft-from-ai flow works with real provider
- [ ] Make "plan my week" discoverable and polished in iOS
- [ ] Review/approve/swap flow works

### R1.3 — Grocery generation
- [ ] Verify regenerate_grocery_for_week works end-to-end
- [ ] iOS grocery view shows clean grouped checklist

### R1.4 — Recipe UX polish
- [ ] Import from URL works reliably against real recipe sites
- [ ] Recipe detail shows editorial presentation (not just a form)
- [ ] Recipe editor functional for manual entry and AI-generated recipes

## R2: Visual Redesign (editorial + AI-forward)

### R2.1 — Design system foundation
- [ ] Color tokens, typography scale, spacing constants
- [ ] Shared components: RecipeCard, MealSlot, GroceryRow, AIPromptBar

### R2.2 — Tab restructure
- [ ] 3 core tabs: Week, Recipes, Assistant
- [ ] Grocery as sub-view of Week (sheet or section)
- [ ] Settings behind gear icon (not a tab)

### R2.3 — Screen-by-screen redesign
- [ ] Week view (home screen)
- [ ] Recipe detail + editor
- [ ] Assistant chat
- [ ] Sign-in / onboarding
- [ ] Grocery view
- [ ] Settings

## R3: TestFlight Prep

- [ ] Fix ASC credentials or use API key auth
- [ ] App icons, launch screen
- [ ] Privacy policy URL
- [ ] App Store metadata
- [ ] Build + archive + upload
- [ ] Internal TestFlight testing

## Execution Order

R1.1 → R1.2 → R1.3 → R1.4 → R2.1 (parallel from R1.2) → R2.2 → R2.3 → R3

## Backlog (parallel, tiered)

<!-- tier3_owner: claude -->

### Opus (design + cross-cutting)
- [ ] Design the AI preference interview conversation flow
- [ ] Design the week planning wizard UX and AI integration
- [ ] Design the freemium gate architecture

## Constraints

- AI is the primary interaction model, not a side feature
- Do not silently persist AI-generated recipes or week changes
- Postgres-only (Fly.io). SQLite only in test suite
- Single-user accounts at launch; design for household sharing post-launch
- MCP/agent access is a launch differentiator
- Freemium AI boundaries TBD — build the product first, add gates later

## Open Decisions

1. AI provider for launch — OpenAI or Anthropic? Both wired.
2. Tab count — 3 (Week/Recipes/Assistant) or 4 (+ Grocery)?
3. Recipe imagery — AI-generated, stock, or text-only?
4. Sign in with Google — include at launch or Apple-only?
