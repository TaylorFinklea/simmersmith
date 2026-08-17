# App Store Connect privacy mapping notes (`5w8`)

Status: current code-grounded starting map as of 2026-08-17. Human must answer the live ASC
questionnaire and accept the legal/product judgments. This file is not a completed label.

## Current product facts

- No SimmerSmith account service or central meal-planning database.
- Household and personal records use the user's iCloud/CloudKit databases.
- Recipe memories and their photos are CloudKit household records; the old Fly exception is gone.
- Optional AI sends requests directly to the provider configured with the user's key.
- Text providers exposed to new users: OpenAI, Anthropic, Ollama Cloud, NeuralWatt.
- Image providers: OpenAI and Gemini.
- No advertising, analytics, crash-reporting, tracking SDK, or MetricKit integration.
- Paywall is disabled; no paid subscription is required in the current product.

## Conservative starting map

| ASC area | Starting answer | Human verification required |
|---|---|---|
| Tracking | No | Confirm no future SDK/config changed before submission. |
| Usage data / diagnostics | No | Recheck if MetricKit or telemetry lands. |
| Purchases | No for current build | Revisit when monetization is enabled. |
| Contact info | Likely No | Decide whether guest names belong under contact info or user content. |
| User content — other | Likely Yes, App Functionality | Recipes, plans, groceries, notes, assistant text, and event context can reach CloudKit and optional AI providers. |
| User content — photos | Likely Yes, App Functionality | User-selected and generated images use CloudKit; selected images may reach an AI provider for a requested feature. |
| Health & fitness | Uncertain | Allergy, dietary-goal, and dietary-note classification requires live ASC/legal review. |
| Audio | Likely No | Raw cook-mode audio goes to Apple's speech framework, not an AI provider; confirm Apple's current treatment of speech recognition. Transcripts are text/user content. |
| Identifiers | Uncertain | No SimmerSmith user/device ID is transmitted to AI providers; CloudKit remains associated with the user's Apple account. |
| Linked to identity | Uncertain | Evaluate iCloud association and each provider's practices in the live form. |

## Why BYO-key still needs a live decision

Apple defines collection around off-device transmission where the developer or third-party partner
can access data longer than needed to service the request in real time. Provider retention differs by
account, product, and policy; a user-supplied key does not by itself prove optional disclosure. Use the
conservative disclosures unless current provider terms and the live ASC wording support a narrower
answer.

Apple's App Review Guidelines also require clear disclosure and explicit permission before sharing
personal data with third-party AI. Before submission, verify the app's provider setup/first-use flow
against that requirement and verify the chosen providers meet Apple's required data protections.

## Human submission checklist

- [ ] Open the live ASC App Privacy questionnaire; do not rely on category names in this note.
- [ ] Resolve Health & Fitness treatment for allergies and dietary goals/notes.
- [ ] Resolve BYO-key provider retention and “collected” treatment for each data type.
- [ ] Resolve whether CloudKit-backed data is linked to identity in Apple's current framing.
- [ ] Confirm explicit consent before third-party AI transmission.
- [ ] Confirm the published privacy URL and in-app Settings link work in the release build.
- [ ] Re-run the claims-vs-code audit if any provider, telemetry, monetization, or data-plane code changes.

References:

- <https://developer.apple.com/app-store/app-privacy-details/>
- <https://developer.apple.com/app-store/review/guidelines/>
