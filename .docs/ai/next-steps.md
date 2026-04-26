# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Immediate (M12 ship)

- [ ] **Deploy backend to Fly** — pairings, difficulty inference,
      seasonal produce, and web-search routes are not live yet:
      ```
      fly deploy
      ```
- [ ] **Cut TestFlight build 16** — version bumped + project
      regenerated; needs archive + upload:
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
- [ ] End-to-end smoke test on a real device (build 16):
  - Recipe detail → "Suggest pairings" → 3 cards render with role
    chips + reasons.
  - Recipes → see Easy/Medium/Hard pills on recently-added recipes;
    filter chips work; Kid-friendly chip filters correctly.
  - Settings → enter "Kansas, USA" as region → save.
  - Week → "In season now" chip strip appears above the day cards;
    tap a chip → modal with "why now" + Find recipes hand-off works.
  - Recipes plus menu → "Find recipe online" → query "best whole
    wheat waffle recipe" → preview card with source URL → "Open in
    editor" → save → recipe lands in the library with citation.

## Awaiting User / External

- [ ] TestFlight build 15 + 16 dogfooding feedback (wife's iPhone)
- [ ] Add internal testers to TestFlight if not done
- [ ] Register at developer.kroger.com — `client_id` + `client_secret`
- [ ] `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=… SIMMERSMITH_KROGER_CLIENT_SECRET=…`

## Recommended Next Milestone

**M13 — Cooking Mode**, the natural follow-up to M11's `cook_check`
seed and the user's earlier choice of "dedicated cook mode +
assistant nested" as the cooking-guidance shape.

- Big-text step view, voice-friendly, hands-free.
- Per-step "Ask the assistant" button pre-loaded with that step's
  context.
- Preserves the M11 photo cook-check chip per step.

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
