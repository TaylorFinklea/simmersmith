# Open-model provider swap — Ollama Cloud + NeuralWatt

Date: 2026-07-09
Status: approved by user
Bead: simmersmith-a7i

## Goal

Replace the user-visible OpenRouter open-model path with Ollama Cloud and NeuralWatt while preserving the existing on-device BYO-key architecture.

## Decisions

- Keep the internal provider tag `openmodels`.
- Add visible open-model vendors:
  - `ollamaCloud` — Keychain id `ollama`, OpenAI-compatible base `https://ollama.com/v1`, chat URL `https://ollama.com/v1/chat/completions`, models URL `https://ollama.com/v1/models`.
  - `neuralwatt` — Keychain id `neuralwatt`, OpenAI-compatible base `https://api.neuralwatt.com/v1`, chat URL `https://api.neuralwatt.com/v1/chat/completions`, models URL `https://api.neuralwatt.com/v1/models`.
- Hide OpenRouter from new Settings selection. Existing direct GLM/Kimi/MiniMax code may remain dormant.
- Do not add `opencode-go`; its subscription/API terms for non-coding app traffic are not verified.
- Use OpenAI-compatible request/response handling already implemented by `BYOKeyProvider`.
- Treat both new providers as `reasoningStyle: .none` for v1: no vendor-specific thinking/reasoning replay params.

## UX

- Settings → AI provider picker shows the existing top-level `openmodels` entry labeled `Open models`.
- The open-model row lets the user choose `Ollama Cloud` or `NeuralWatt`, then a model.
- Each provider has its own local Keychain key. Keys are never sent to SimmerSmith servers or iCloud.
- Model lists use curated fallbacks plus `Custom…`; live `/models` fetch remains best-effort when a key is present.

## Initial model lists

- Ollama Cloud: `glm-5.2`, `kimi-k2.6`, `minimax-m3`.
- NeuralWatt: `glm-5.2`, `glm-5.2-short`, `glm-5.2-fast`, `glm-5.2-short-fast`, `kimi-k2.6`, `kimi-k2.6-fast`.

## Verification

- `swift test --package-path SimmerSmithCloudKit`
- App build if source changes outside the package require it: `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO`
