# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Requires Your Action

- [ ] Confirm `SIMMERSMITH_AI_OPENAI_API_KEY` is set on Fly so the planning
      tool loop actually fires in production
- [ ] Try the sparkle button on a real build end-to-end (simulator or device)
      and verify tool-call cards render, meals change live, no 500s
- [ ] Register at developer.kroger.com — get client_id/secret
- [ ] `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=... SIMMERSMITH_KROGER_CLIENT_SECRET=...`
- [ ] Configure Google Cloud Console: add iOS client ID for `app.simmersmith.ios` bundle
- [ ] Test full flow on TestFlight build: sign in → onboarding → plan week → grocery → share recipe
- [ ] Add internal testers to TestFlight

## Immediate (M6 polish)

- [ ] Live shakedown of the planning tool loop against real OpenAI (not just the monkeypatched test)
- [ ] Incremental `generate_week_plan` (stream one day at a time; emit `week.updated` per day)
- [ ] Per-day "Ask AI" button + active-chat chip on Week page
- [ ] Anthropic tool-use support (current loop only runs on OpenAI-direct; Anthropic falls back to envelope path)
- [ ] Deploy backend to Fly
- [ ] Cut a new TestFlight build

## Soon

- [ ] Fetch pricing button — already exists; wire it as a suggested chat prompt
- [ ] Instacart "shop now" button (affiliate integration)
- [ ] Spoonacular estimated pricing fallback
- [ ] App Store metadata + screenshots
- [ ] App Store submission

## Future

- [ ] Household sharing
- [ ] Recipe images
- [ ] Remote push notifications from backend
