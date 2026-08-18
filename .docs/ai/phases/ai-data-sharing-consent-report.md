# AI data-sharing consent report

Status: implemented and verified; ready for the next release candidate.

## Shipped behavior

- Cloud AI defaults off for every provider until the user explicitly allows that provider.
- Settings names the provider and discloses request data categories before Allow / Not Now.
- Consent is versioned, device-local, independently revocable, and reset by key save/replacement/clear.
- Text, vision, assistant, model/key test, image generation, and image-failover paths share one gate.
- Gemini failover requires its own key and consent; OpenAI consent never authorizes Gemini.
- Privacy policy documents the permission and revocation behavior.

## Verification

- `AIDataSharingConsentTests` — 9/9 passed, including policy invalidation and Gemini failover.
- `python3 -m unittest tests/test_legal_site.py` — 3/3 passed.
- `swift test --package-path SimmerSmithKit` — passed with known entitled-host skips.
- `swift test --package-path SimmerSmithCloudKit` — 704/704 passed.
- iOS simulator `build-for-testing` — succeeded.
- `git diff --check` — clean before handoff.

## External gates

- Next RC: physical-device smoke of save key → disclosure → Not Now/Allow → revoke.
- Human legal review and App Store Connect privacy questionnaire remain required.
- Build 177 Roshar photo/participant gates remain independent.
