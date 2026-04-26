# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-26

Shipped **M13 Cooking Mode** in four phases on dev. Build is queued
at `CURRENT_PROJECT_VERSION 17` but **NOT yet uploaded to TestFlight**.
M13 is iOS-only — no backend changes — so no Fly deploy is needed.

M11 (Photo-First AI) and M12 (Quick AI Wins) shipped in earlier
sessions. M13 builds on top of M11's `cook_check` chip and the
existing assistant launch context to give the user a hands-free,
big-text, screen-awake cook flow.

### What landed this session (M13)

**Phase 1 — Cooking Mode skeleton (commit `303482c`)**
- New `Features/Cooking/CookingModeView.swift` — full-screen
  `.fullScreenCover`, big-text serif step text, top progress bar,
  prev / next / ask-assistant / exit buttons, wake-lock via
  `UIApplication.isIdleTimerDisabled`. Long-press step text →
  existing M11 `CookCheckSheet`.
- `RecipeDetailView` gains a frying-pan toolbar button + a prominent
  "Start cooking" button at the bottom of the steps section. Both
  present `CookingModeView(recipeID:)`.

**Phase 2 — TTS step readout (commit `4c5c3d0`)**
- New `Services/SpokenStepService.swift` — `@Observable`,
  `AVSpeechSynthesizer` wrapper. Mute pref persists via UserDefaults
  (`cooking.tts.muted`). Activates AVAudioSession with `.playback`
  / `.spokenAudio` / `.duckOthers` so background music ducks during
  speech.
- `CookingModeView` reads the current step on entry and on every
  `stepIndex` change. Mute toggle in the top bar (`speaker.wave.2.fill`
  / `speaker.slash.fill`).

**Phase 3 — Voice commands (commit `c8fd246`)**
- New `Services/VoiceCommandService.swift` — `@Observable`, on-device
  `SFSpeechRecognizer` + `AVAudioEngine` continuous tap. Recognizes
  next / next step / previous / back / go back / repeat / again /
  stop / pause / exit. Auto-restarts the recognition request every
  ~50 seconds (and after every keyword) to dodge the ~1-minute audio
  buffer limit. Exposes `AsyncStream<VoiceCommand>`.
- Permission helpers for `SFSpeechRecognizer` + `AVAudioApplication`.
- `CookingModeView` mic toggle, live-caption pill showing the running
  transcript, `.task` consumer for the command stream, "Stop cooking?"
  confirmation alert when "stop" is heard.
- `Info.plist` adds `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription`.

**Phase 4 — Manual quick timers + per-step polish (commit pending)**
- New `Features/Cooking/CookingTimerChip.swift` — 5/10/15/20/Custom
  pill row with concurrent countdowns. At 0:00: warning haptic +
  TTS announces "Timer done." (no audio asset needed). 5-second
  "Timer done" pill before auto-clearing.
- "Check it" button promoted to a visible chip beside the timer row.
- Final-step "Done" calls `onCompleted` on dismiss; `RecipeDetailView`
  shows a "Nicely done." toast via the existing `preferenceToast`
  overlay.
- `project.yml` `CURRENT_PROJECT_VERSION` 16 → 17.

### Production state

- **URL**: https://simmersmith.fly.dev (healthy; current = M12 — no
  M13 backend work, so still aligned).
- **TestFlight**: build 16 (M12). Build 17 archived locally is
  **NOT** yet uploaded — pending user-confirmed action.

### Build status

- Backend: pytest 180/180 pass (no changes; reconfirmed)
- Swift tests: 26/26 pass
- iOS build: green on `generic/platform=iOS Simulator`
- Fly production: healthy (M12, unchanged)
- TestFlight: STALE wrt M13 (build 17 not yet uploaded)

## Files Changed (this session)

iOS (new):
- `SimmerSmith/SimmerSmith/Features/Cooking/CookingModeView.swift`
- `SimmerSmith/SimmerSmith/Features/Cooking/CookingTimerChip.swift`
- `SimmerSmith/SimmerSmith/Services/SpokenStepService.swift`
- `SimmerSmith/SimmerSmith/Services/VoiceCommandService.swift`

iOS (extended):
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipeDetailView.swift`
  (toolbar pan-icon button, "Start cooking" bottom button,
  `.fullScreenCover`, completion-toast helper)
- `SimmerSmith/SimmerSmith/Info.plist`
  (mic + speech-recognition usage descriptions)
- `SimmerSmith/project.yml`
  (`CURRENT_PROJECT_VERSION` 16 → 17)

Docs:
- `.docs/ai/roadmap.md` — M12 marked shipped; M13 added + marked complete on dev
- `.docs/ai/current-state.md` — this file
- `.docs/ai/next-steps.md` — refreshed for build 17 upload
- `.docs/ai/decisions.md` — appended ADR on on-device-only voice + manual timers
