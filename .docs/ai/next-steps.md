# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Requires Your Action

- [ ] Deploy M7 Phases 1–4 to fly.io: `fly deploy`
- [ ] Cut a new TestFlight build (v1.0.0 build 4+) with M6 + M7 Phases 1–4
- [ ] End-to-end test on a real device (simulator can't fully reproduce
      the URLSession cancel surface):
  - Open assistant sheet, send "Swap Tuesday dinner for something lighter"
  - While streaming, pull-to-refresh on Week → stream must NOT error (Phase 1)
  - Start a turn, dismiss the sheet immediately → backend logs should
    show abort fired, DB row should have `status="cancelled"` (Phase 3)
  - Ask "did you swap it?" when nothing changed → amber "Nothing
    changed" affordance appears (Phase 4)
- [ ] Register at developer.kroger.com — get client_id/secret
- [ ] `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=... SIMMERSMITH_KROGER_CLIENT_SECRET=...`
- [ ] Configure Google Cloud Console: add iOS client ID for `app.simmersmith.ios` bundle
- [ ] Add internal testers to TestFlight

## Immediate (M7 Phases 5 + 6 — deferred this session)

- [ ] Phase 5: Anthropic tool-use support — refactor `_run_openai_tool_loop`
      into a provider-agnostic `_run_tool_loop(adapter, ...)` with
      OpenAI + Anthropic stream adapters. Plan doc:
      `/Users/tfinklea/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`
- [ ] Phase 6: True per-day `generate_week_plan` — one AI call per day
      with prior days in context. 7× tokens on a full week; flag cost
      impact before shipping since freemium gating is postponed.

## Soon

- [ ] Instacart "shop now" affiliate integration
- [ ] Spoonacular estimated pricing fallback
- [ ] App Store metadata (description, keywords, category, screenshots)
- [ ] Submit for App Store review

## Future

- [ ] Household sharing tied to a Pro seat
- [ ] Recipe images (AI-generated or fetched)
- [ ] Smart substitutions powered by ingredient preferences
- [ ] Remote push notifications from backend (APNs integration)
- [ ] Proactive intelligence (leftover tracking, weekly theme,
      calendar-aware planning)

## Deferred

- **M5 Freemium + Subscription**: postponed at user's request on
  2026-04-20. Do not restart without explicit re-authorization. Saved
  to memory (`project_m5_freemium_deferred.md`).
