# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Requires Your Action

- [ ] Register at developer.kroger.com — get client_id/secret
- [ ] `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=... SIMMERSMITH_KROGER_CLIENT_SECRET=...`
- [ ] Configure Google Cloud Console: add iOS client ID for `app.simmersmith.ios` bundle
- [ ] Add `GIDClientID` to Info.plist (or env-based config) with Google client ID
- [ ] Test full flow on TestFlight build: sign in → onboarding → plan week → grocery → share recipe
- [ ] Add internal testers to TestFlight

## Immediate (code work)

- [ ] Verify iOS build succeeds with GoogleSignIn SPM dependency
- [ ] App Store metadata (description, keywords, category, screenshots)
- [ ] Fetch pricing button in iOS grocery view (trigger backend pricing fetch)

## Soon

- [ ] Instacart "shop now" button (affiliate integration)
- [ ] Spoonacular estimated pricing fallback
- [ ] App Store submission

## Future

- [ ] Freemium boundaries
- [ ] Household sharing
- [ ] Recipe images
- [ ] Remote push notifications from backend
