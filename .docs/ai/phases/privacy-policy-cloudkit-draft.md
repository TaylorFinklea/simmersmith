# SimmerSmith Privacy Policy — release record (`5w8`)

Status: promoted into `docs/privacy/index.html` on branch `codex/privacy-terms-rehost`.
Publication is still pending merge/push and GitHub Pages verification.

## Canonical release content

- Privacy: `docs/privacy/index.html`
- Terms: `docs/terms/index.html`
- In-app URLs: `SimmerSmithKit/Sources/SimmerSmithKit/Configuration/LegalDocumentURLs.swift`
- ASC mapping: `privacy-policy-asc-label-notes.md`

Do not maintain a second prose copy here. Edit the HTML policy, then refresh this audit.

## Claims-vs-code audit — 2026-08-17

- iCloud household/private planes: `HouseholdRecords`, `HouseholdSync`, `HouseholdSession`,
  `ProfileRepository`, `PreferenceRepository`, `AssistantRepository`.
- Household content includes recipe memories and photos: `RecipeRepository` uses
  `RecipeMemory` plus `RecipeMemoryImage` CKAsset records; no live Memories/Fly exception remains.
- BYO keys: `AIProviderKit/KeyStore.swift` uses
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; keys are absent from CloudKit and backups.
- User-selectable text providers: OpenAI, Anthropic, Ollama Cloud, NeuralWatt. OpenRouter is
  compatibility-only and excluded by `ProviderRegistry.allOpenModelVendors`.
- User-selectable image providers: OpenAI and Gemini (`ImageGenProvider.swift`).
- Cloud AI requests originate on-device via `BYOKeyProvider`; no SimmerSmith proxy is used.
- Photos: user-selected items use `PhotosPicker`; camera permission remains for recipe scanning.
- Speech: cook-mode `VoiceCommandService` prefers on-device recognition but allows Apple's speech
  service fallback when the local recognizer is unavailable. Voice planning uses keyboard dictation
  or typed text; its transcript may be sent to the configured provider for cloud parsing.
- Reminders: full EventKit access is optional and scoped by app logic to the chosen list.
- Notifications: visible reminders are local; remote-notification mode supports CloudKit sync.
- Backups: rolling JSON household snapshots live in Application Support; keys/personal plane are
  not part of `HouseholdBackup`.
- No third-party advertising, analytics, crash-reporting, tracking SDK, or MetricKit integration was
  found. `PrivacyInfo.xcprivacy` declares no collected data and no tracking.

## Human review gates

- Legal review remains the publisher's responsibility; this is a code-grounded product draft, not
  legal advice.
- Apple's current App Review Guidelines require an easily accessible in-app privacy link; Settings
  → About now exposes Privacy Policy and Terms of Use.
- Apple also requires clear third-party AI disclosure and explicit permission before sharing
  personal data with third-party AI. Confirm the current provider-setup/first-use experience meets
  that consent standard before submission.
- Confirm how the live ASC questionnaire classifies BYO-key AI, allergy/dietary data, iCloud data,
  and user-selected photos. Do not copy old answers without re-evaluating them.
- Publish only after merging/pushing and verifying both final Pages URLs return the intended pages.

References:

- <https://developer.apple.com/app-store/review/guidelines/>
- <https://developer.apple.com/app-store/app-privacy-details/>
