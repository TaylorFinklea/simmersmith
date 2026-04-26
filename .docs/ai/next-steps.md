# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Immediate (M13 ship)

- [ ] **Cut TestFlight build 17** — `CURRENT_PROJECT_VERSION` is
      already 17 and the project is regenerated; needs archive +
      upload:
      ```
      xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj \
        -scheme SimmerSmith -configuration Release \
        -archivePath /tmp/SimmerSmith.xcarchive \
        -destination 'generic/platform=iOS' archive

      xcodebuild -exportArchive \
        -archivePath /tmp/SimmerSmith.xcarchive \
        -exportPath /tmp/SimmerSmith-export \
        -exportOptionsPlist SimmerSmith/ExportOptions.plist
      ```
- [ ] End-to-end smoke test on a real device (build 17):
  - Recipe detail → tap pan icon → cook mode opens. Cook mode
    reads the first step aloud.
  - Tap mic → grant mic + speech permissions → say "next" / "back"
    / "repeat" → cook view advances/retreats/re-reads. Say "stop"
    → confirmation alert → confirm → returns to detail view.
  - Tap a 10-min timer chip → countdown starts → wait → haptic +
    TTS "Timer done." fires.
  - Tap "Check it" on a step → photo → verdict + tip card (M11
    cook-check still works inside cook mode).
  - Tap "Ask assistant" mid-cook → cook mode dismisses → assistant
    tab opens with the prefilled "I'm cooking X and on step Y…"
    message.
  - Reach final step → tap Done → returns to recipe detail with
    "Nicely done." toast.
  - Confirm screen does not auto-lock during a 30-second idle in
    cook mode.

## Awaiting User / External

- [ ] TestFlight build 16 + 17 dogfooding feedback (wife's iPhone)
- [ ] Add internal testers to TestFlight if not done
- [ ] Register at developer.kroger.com — `client_id` + `client_secret`
- [ ] `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=… SIMMERSMITH_KROGER_CLIENT_SECRET=…`

## Recommended Next Milestone

**Recipe memories** — inline notes + photos saved per recipe across
cooks. Smaller scope than M13. Adds a per-recipe memory model
(text + optional photo) and a sub-view in `RecipeDetailView`.

After memories, the next product candidates from `## Future` are:
**household sharing** (Pro seat) and **recipe images via image-gen**
(Gemini 3.1 Flash Image Preview via Vercel AI Gateway).

## Deferred (M7 Phases 5 + 6)

- [ ] Phase 5: Anthropic tool-use support — refactor
      `_run_openai_tool_loop` into a provider-agnostic adapter.
- [ ] Phase 6: True per-day `generate_week_plan` (7× tokens; flag
      cost before shipping).

## Soon

- [ ] Anthropic web search support for the recipe finder (Messages
      API `web_search_20250305` tool — currently OpenAI-only).
- [ ] Backfill helper: a Settings button that runs difficulty
      inference on every recipe still missing a score.
- [ ] Instacart "shop now" affiliate integration (M2 secondary)
- [ ] Spoonacular estimated pricing fallback (M2 secondary)

## Future

- [ ] Memories on recipes (inline notes + photos per recipe)
- [ ] Recipe images via image-gen (Gemini 3.1 Flash Image Preview
      via Vercel AI Gateway)
- [ ] Household sharing tied to a Pro seat
- [ ] Remote push notifications (APNs)

## Deferred (do not restart without authorization)

- **M5 Freemium + Subscription**: postponed 2026-04-20. Saved to
  memory (`project_m5_freemium_deferred.md`).
