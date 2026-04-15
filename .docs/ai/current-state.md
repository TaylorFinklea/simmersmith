# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-14

Massive feature sprint + TestFlight upload. Built 8 features, fixed the provisioning profile blocker, and uploaded build 3 to App Store Connect.

**What was done:**
- AI onboarding preference interview (4-step: household, diet, cuisine, cooking style)
- AI recipe creation from meal notes ("grilled chicken" → full recipe via AI)
- Push notifications (local meal reminders + grocery day)
- Privacy policy page at /privacy
- Week approval flow (approve all + per-meal approve/unapprove)
- Recipe sharing (ShareLink with formatted text)
- Better empty states (Recipes + Assistant with actionable prompts)
- Meal rating in week view via FeedbackComposerView
- Fixed app icon alpha channel (App Store requires opaque PNGs)
- Created manual App Store provisioning profile via ASC API (bypassed stale cloud signing)
- Switched to manual signing in ExportOptions.plist
- **Successfully uploaded v1.0.0 build 3 to TestFlight**

## Production

- **URL**: https://simmersmith.fly.dev
- **Privacy Policy**: https://simmersmith.fly.dev/privacy
- **API Token**: `299dab5eca45445da9270e8d1f101d1b`
- **TestFlight**: v1.0.0 build 3 uploaded, processing on App Store Connect

## Build Status

- Backend: ruff ✅, pytest 65/65 ✅
- iOS: BUILD SUCCEEDED ✅
- Swift tests: 26/26 ✅
- TestFlight: **UPLOADED** (build 3)
- Production: deployed and healthy ✅

## Key Credentials (do not commit)

- ASC API Key ID: `7R3R6JP368`
- ASC Issuer ID: `fe27785a-1413-46ff-bd82-111de0da024f`
- APNs Key ID: `46NXHV5UB8`
- Team ID: `K7CBQW6MPG`
- Bundle ID: `app.simmersmith.ios`
- Manual provisioning profile: `SimmerSmith App Store` (ID: Y37ZM5DXYY)

## Architecture

- **Backend**: FastAPI + SQLAlchemy on Fly.io (simmersmith app) + Fly Postgres (simmersmith-db)
- **Auth**: Apple Sign-In (JWKS verification via pyjwt) → session JWT. Legacy bearer fallback.
- **AI**: OpenAI (gpt-5.4-mini) for week planning + recipe generation. Key set via `fly secrets`.
- **iOS**: SwiftUI, 3-tab layout (Week/Recipes/Assistant), dark theme design system (SMColor/SMFont/SMSpacing/SMRadius)
- **Notifications**: Local (UNUserNotificationCenter) for meal/grocery reminders. Remote push infrastructure ready (APNs key exists, entitlements set).

## Blockers

None critical. TestFlight is uploading.

## Recent Commits

```
d45df53 build: fix TestFlight upload with opaque icons and manual signing
d6c7241 feat: week approval, recipe sharing, empty states, meal rating
04cefbf feat: push notification support with meal and grocery reminders
63296ff feat: add privacy policy page for App Store submission
7e87f5e feat: add AI recipe creation from meal notes in week view
7c4315c feat: add AI onboarding preference interview
```
