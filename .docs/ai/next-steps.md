# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Awaiting User / External

- [ ] TestFlight build 14 dogfooding feedback (wife is live tester on
      the Event Plans surface — Easter use case)
- [ ] Add internal testers to TestFlight (if not done)
- [ ] Register at developer.kroger.com — `client_id` + `client_secret`
- [ ] `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=… SIMMERSMITH_KROGER_CLIENT_SECRET=…`
- [ ] Configure Google Cloud Console iOS client ID for `app.simmersmith.ios`

## Recommended Next Milestone

The product is feature-complete for an MVP launch. The two most
impactful directions:

1. **M3 App Store submission push** — write metadata, take screenshots,
   submit for review. Unblocks public launch. Roughly:
   - App Store description, keywords, category
   - Screenshot generation (Week, Recipes, Assistant, Events)
   - Submit binary 14 for review
2. **M11 Recipe Images** (post-launch growth, listed in M7) — visual
   polish that materially changes how the app *feels*. AI-generated
   thumbnail per recipe via Gemini 3.1 Flash Image Preview through
   Vercel AI Gateway (`google/gemini-3.1-flash-image-preview` —
   faster + cheaper than DALL·E), cached on Fly volume. Recipes
   gallery and Week meal cards become instantly more compelling.

Either is a clean next milestone. Defaulting to **M3** unless the
user wants the visual polish first.

## Deferred (M7 Phases 5 + 6)

- [ ] Phase 5: Anthropic tool-use support — refactor
      `_run_openai_tool_loop` into a provider-agnostic
      `_run_tool_loop(adapter, …)`. `anthropic_tools_schema()` already
      exists at `assistant_ai.py:758–766`.
- [ ] Phase 6: True per-day `generate_week_plan` — one AI call per day
      with prior days in context. 7× tokens; flag cost before shipping
      since freemium gating is postponed.

## Soon

- [ ] Instacart "shop now" affiliate integration (M2 secondary)
- [ ] Spoonacular estimated pricing fallback (M2 secondary)

## Future

- [ ] Recipe images (AI-generated or fetched) — see M11 above
- [ ] Household sharing tied to a Pro seat
- [ ] Remote push notifications (APNs)
- [ ] Proactive intelligence (leftover tracking, weekly theme,
      calendar-aware planning)

## Deferred (do not restart without authorization)

- **M5 Freemium + Subscription**: postponed 2026-04-20. Saved to
  memory (`project_m5_freemium_deferred.md`).
