# Open-model Provider Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the visible OpenRouter provider with Ollama Cloud and NeuralWatt in the existing `openmodels` path.

**Architecture:** Keep `ai_direct_provider == "openmodels"`; model/vendor selection continues to resolve through `OpenModelVendor` + `ProviderRegistry`. Add descriptors/catalog entries for Ollama Cloud and NeuralWatt, then update the Settings picker to offer provider sections instead of a single pinned OpenRouter vendor.

**Tech Stack:** Swift 6.2, SwiftUI, AIProviderKit SPM, Swift Testing.

## Global Constraints

- Do not store API keys in CloudKit; use Keychain ids only.
- Do not add `opencode-go`.
- Do not change OpenAI/Anthropic behavior.
- Follow TDD: tests fail before provider production code changes.

---

### Task 1: Provider descriptor/catalog tests and implementation

**Files:**
- Modify: `SimmerSmithCloudKit/Sources/AIProviderKit/AIProvider.swift`
- Modify: `SimmerSmithCloudKit/Sources/AIProviderKit/ProviderDescriptor.swift`
- Modify: `SimmerSmithCloudKit/Sources/AIProviderKit/AIModelCatalog.swift`
- Test: `SimmerSmithCloudKit/Tests/AIProviderKitTests/ProviderDescriptorTests.swift`
- Test: `SimmerSmithCloudKit/Tests/AIProviderKitTests/OpenModelsProviderTests.swift`

**Interfaces:**
- Produces `OpenModelVendor.ollamaCloud` and `.neuralwatt`.
- `ProviderRegistry.descriptor(for:)` maps each vendor to URL, Keychain id, default model, fallback models.
- `ProviderRegistry.vendor(forKeychainID:)` maps `ollama` and `neuralwatt`.

- [ ] Write failing descriptor tests for Ollama Cloud and NeuralWatt.
- [ ] Run `swift test --package-path SimmerSmithCloudKit --filter ProviderDescriptorTests` and confirm failure on missing enum cases/descriptors.
- [ ] Add enum cases, labels, descriptors, and catalog fallback support.
- [ ] Re-run descriptor/catalog tests and confirm pass.

### Task 2: Settings picker tests and implementation

**Files:**
- Modify: `SimmerSmith/SimmerSmith/Features/Settings/OpenModelsPickerRow.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState+AI.swift`

**Interfaces:**
- `OpenModelsPickerRow` offers visible vendors `[.ollamaCloud, .neuralwatt]`.
- Selecting a model sets both `aiOpenModelsVendorDraft` and `aiOpenModelsModelDraft`.
- Empty open-model vendor defaults to `.ollamaCloud`, not OpenRouter.

- [ ] Write or update host-testable pure helpers where possible; otherwise use compile/build verification for SwiftUI wiring.
- [ ] Replace pinned OpenRouter picker with provider-sectioned Ollama/NeuralWatt picker plus Custom field.
- [ ] Relabel Settings provider row from `OpenRouter` to `Open models`.
- [ ] Default empty open-model vendor to Ollama Cloud.

### Task 3: Full verification and closeout

**Files:**
- Modify: `.docs/ai/current-state.md`
- Modify if needed: `.docs/ai/decisions.md`

- [ ] Run `swift test --package-path SimmerSmithCloudKit`.
- [ ] Run app build: `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO`.
- [ ] Update handoff docs with validation status.
- [ ] Close bead `simmersmith-a7i` if verification passes.
- [ ] Commit code + docs.
