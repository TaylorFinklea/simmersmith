# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Immediate (M11 ship)

- [ ] **Deploy backend to Fly** — vision/products/cook-check routes
      are not live yet:
      ```
      fly deploy
      ```
- [ ] **Cut TestFlight build 15** — version bumped + project
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
- [ ] End-to-end smoke test on a real device (build 15):
  - Recipes plus menu → "Identify ingredient" → photo of any
    produce → result card with cuisine uses appears.
  - Recipe detail → step row → "Check it" camera chip → photo →
    verdict + tip render inline.
  - Grocery view (with Kroger store selected) → barcode toolbar
    button → scan a UPC → product card with brand + price.

## Awaiting User / External

- [ ] TestFlight build 15 dogfooding feedback (wife's iPhone)
- [ ] Add internal testers to TestFlight if not done
- [ ] Register at developer.kroger.com — `client_id` + `client_secret`
- [ ] `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=… SIMMERSMITH_KROGER_CLIENT_SECRET=…`

## Recommended Next Milestone

**M12 Quick AI Wins** — light follow-on to M11. Single AI calls,
mostly stitched into existing surfaces:

- Pairings on recipe detail ("things that go well with this")
- In-season produce snapshot on the Week tab (location + month)
- AI recipe web search ("find me the best whole wheat waffle recipe")
- Beginner / kid-friendly recipe paths (curated + difficulty scoring)

## Deferred (M7 Phases 5 + 6)

- [ ] Phase 5: Anthropic tool-use support — refactor
      `_run_openai_tool_loop` into provider-agnostic
      `_run_tool_loop(adapter, …)`.
- [ ] Phase 6: True per-day `generate_week_plan` (7× tokens; flag
      cost before shipping).

## Soon

- [ ] Instacart "shop now" affiliate integration (M2 secondary)
- [ ] Spoonacular estimated pricing fallback (M2 secondary)

## Future

- [ ] Cooking guidance — dedicated cook mode (voice-friendly,
      hands-free, full-screen) with assistant nested. The cook-check
      MVP from M11 is the seed.
- [ ] Memories on recipes (inline notes + photos per recipe)
- [ ] Recipe images (M11 cook-check sets up the vision provider; an
      image-gen path could now reuse the same routing — Gemini 3.1
      Flash Image Preview via Vercel AI Gateway)
- [ ] Household sharing tied to a Pro seat
- [ ] Remote push notifications (APNs)

## Deferred (do not restart without authorization)

- **M5 Freemium + Subscription**: postponed 2026-04-20. Saved to
  memory (`project_m5_freemium_deferred.md`).
