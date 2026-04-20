# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Requires Your Action

- [ ] End-to-end test the Nebular overlay on a rebuilt iOS: sparkle → ask
      for a meal swap → verify tool-call card appears + Week page updates
      live (page_context + streaming + tool loop wired up to prod)
- [ ] Cut a new TestFlight build with M6 + Nebular overlay
- [ ] Register at developer.kroger.com — get client_id/secret
- [ ] `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=... SIMMERSMITH_KROGER_CLIENT_SECRET=...`
- [ ] Configure Google Cloud Console: add iOS client ID for `app.simmersmith.ios` bundle
- [ ] Add internal testers to TestFlight

## Immediate (M7 assistant polish)

- [ ] Investigate the "cancelled" error that shows on pull-to-refresh after
      closing the assistant sheet mid-stream — likely URLSession cancellation
      cascading from the dismissed sheet to the in-flight stream
- [ ] Guardrail: if the AI text describes a tool-like action but no tool was
      called that turn, append a "Nothing changed — want me to actually do it?"
      affordance so users don't get fooled by hallucinations
- [ ] Persist streamed deltas server-side as they arrive so refresh mid-stream
      shows partial content (today `content_markdown` only writes on
      completion)
- [ ] Cancel the server-side turn when the user dismisses the sheet mid-stream
      (hook into AsyncThrowingStream onTermination → abort the SSE on server)
- [ ] Anthropic tool-use support (OpenAI-direct only today; Anthropic falls
      back to envelope-JSON without tool access)
- [ ] True per-day AI generation for `generate_week_plan` (one call per day
      for real progressive reveal; current impl is one call + day-by-day
      application)

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
