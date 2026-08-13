# Recipe Photo Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render existing recipe photos across every shared recipe image surface while preserving the current illustration as the immediate and failure fallback.

**Architecture:** `RecipeRecordMapper` derives a local cache token from the existing `RecipeImage.generatedAt` value, and `RecipeRepository` supplies that revision without decoding the asset. An AppState-owned `RecipeImageLoader` coalesces fetches, downsamples off-main, and caches bounded decoded images; `RecipeHeaderImage` owns stale-request-safe presentation state and retries only unresolved assets after a store-generation change.

**Tech Stack:** Swift 6.2, SwiftUI, Observation, UIKit, ImageIO, CloudKit, Swift Testing, XcodeGen.

## Global Constraints

- iOS deployment target remains 26.0; no compatibility branch or new dependency.
- Keep the illustration as the immediate, missing-asset, decode-failure, and not-yet-downloaded fallback.
- Downsample away from the main actor to a maximum 1024-pixel dimension.
- Use one decoded-image `NSCache` with `countLimit = 40`; retain no raw image bytes after decoding.
- No CloudKit schema, backend, Fly.io, web, generation-policy, provider-selection, or automatic-backfill change.
- Do not touch onboarding lifecycle, mutation durability, household authority, signing, build 174, or local `main`.
- Red-green TDD; one focused commit per independently reviewable task.
- No push, TestFlight upload, build-number bump, or merge to `main`.

---

## File map

- `SimmerSmithKit/.../RecipeRecordMapper.swift` + tests — revisioned local image token.
- `SimmerSmith/.../RecipeImageLoader.swift` + app-host tests — decode, cache, coalescing, invalidation, and presentation state.
- `SimmerSmith/.../RecipeRepository.swift` + live-update tests — image metadata to mapper.
- `SimmerSmith/.../AppState.swift` and `AppState+Recipes.swift` — loader ownership and legacy invalidation.
- `SimmerSmith/.../RecipeHeaderImage.swift` and `RecipeDetailView.swift` — shared rendering and restored controls.
- `SimmerSmith.xcodeproj/project.pbxproj` — XcodeGen output for new files.
- `.docs/ai/` phase state and report — verification evidence and human gate.

### Task 1: Revisioned CloudKit image token

**Files:**
- Modify: `SimmerSmithKit/Tests/SimmerSmithKitTests/RecipeRecordMapperTests.swift`
- Modify: `SimmerSmithKit/Sources/SimmerSmithKit/CloudKit/RecipeRecordMapper.swift`

**Interfaces:**
- Consumes: existing `recipe(from:ingredients:steps:hasImage:)` callers.
- Produces: the same method with `imageGeneratedAt: Date? = nil`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func imageGenerationDateRevisionsOnlyTheImageUrlToken() {
    let recipe = makeRecipe(["recipeId": "R6-revision", "name": "Revisioned Image"])
    let records = RecipeRecordMapper.records(from: recipe)
    let firstDate = Date(timeIntervalSinceReferenceDate: 100)
    let secondDate = Date(timeIntervalSinceReferenceDate: 200)
    let first = RecipeRecordMapper.recipe(
        from: records.recipe, ingredients: [], steps: [], hasImage: true,
        imageGeneratedAt: firstDate)
    let same = RecipeRecordMapper.recipe(
        from: records.recipe, ingredients: [], steps: [], hasImage: true,
        imageGeneratedAt: firstDate)
    let replacement = RecipeRecordMapper.recipe(
        from: records.recipe, ingredients: [], steps: [], hasImage: true,
        imageGeneratedAt: secondDate)
    let absent = RecipeRecordMapper.recipe(
        from: records.recipe, ingredients: [], steps: [], hasImage: false,
        imageGeneratedAt: secondDate)
    #expect(first.imageUrl == same.imageUrl)
    #expect(first.imageUrl != replacement.imageUrl)
    #expect(first.imageUrl?.hasPrefix("ckasset://R6-revision?revision=") == true)
    #expect(absent.imageUrl == nil)
}
```

- [ ] **Step 2: Confirm red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit --filter imageGenerationDateRevisionsOnlyTheImageUrlToken
```

Expected: compile failure because the parameter is absent.

- [ ] **Step 3: Implement the token**

Add `imageGeneratedAt: Date? = nil` after `hasImage` and replace the image mapping block with:

```swift
if hasImage {
    let revision = imageGeneratedAt?.timeIntervalSinceReferenceDate.bitPattern ?? 0
    dict["imageUrl"] = "ckasset://\(rec.recordName)?revision=\(String(revision, radix: 16))"
}
```

`hasImage` remains the presence signal, so older records receive a stable revision-zero token.

- [ ] **Step 4: Verify and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit --filter RecipeRecordMapper
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit
git add SimmerSmithKit/Sources/SimmerSmithKit/CloudKit/RecipeRecordMapper.swift SimmerSmithKit/Tests/SimmerSmithKitTests/RecipeRecordMapperTests.swift
git commit -m "feat(recipes): revision recipe image tokens"
```

Expected: PASS.

### Task 2: Bounded coalescing image loader

**Files:**
- Create: `SimmerSmith/SimmerSmith/Features/Recipes/RecipeImageLoader.swift`
- Create: `SimmerSmith/SimmerSmithTests/RecipeImageLoaderTests.swift`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Fetcher = @MainActor (String) async throws -> Data`, matching `AppState.fetchRecipeImageBytes(recipeID:)`.
- Produces: `image(recipeID:imageToken:)`, `invalidate(recipeID:)`, `revision(for:)`, `RecipeImageRequestID`, and `RecipeImagePresentationState`.

- [ ] **Step 1: Write failing loader tests**

Create an `@MainActor` Swift Testing suite with these fixtures and assertions:

```swift
@Test func nilTokenDoesNotFetch() async {
    var fetchCount = 0
    let loader = RecipeImageLoader(
        fetcher: { _ in fetchCount += 1; return Data([1]) },
        decoder: { _, _ in UIImage() })
    #expect(await loader.image(recipeID: "A", imageToken: nil) == nil)
    #expect(fetchCount == 0)
}

@Test func validBytesDecodeOnceAndCache() async {
    var fetchCount = 0
    var decodeCount = 0
    let expected = UIImage()
    let loader = RecipeImageLoader(
        fetcher: { _ in fetchCount += 1; return Data([1]) },
        decoder: { _, maximumDimension in
            decodeCount += 1
            #expect(maximumDimension == 1024)
            return expected
        })
    #expect(await loader.image(recipeID: "A", imageToken: "one") === expected)
    #expect(await loader.image(recipeID: "A", imageToken: "one") === expected)
    #expect(fetchCount == 1)
    #expect(decodeCount == 1)
    #expect(loader.cacheCountLimit == 40)
}

@Test func corruptBytesReturnNilAndAreNotCached() async {
    var fetchCount = 0
    let loader = RecipeImageLoader(fetcher: { _ in
        fetchCount += 1
        return Data("not an image".utf8)
    })
    #expect(await loader.image(recipeID: "A", imageToken: "bad") == nil)
    #expect(await loader.image(recipeID: "A", imageToken: "bad") == nil)
    #expect(fetchCount == 2)
}
```

Add a continuation-gated test that starts two requests for A/shared and expects one fetch/decode. Add a targeted-invalidation test that primes A and B, invalidates A, and expects fetch counts A=2/B=1 and revisions A=1/B=0. Add a presentation test that completes an older epoch after a newer one and expects only the newer `UIImage`; unresolved state retries, completed state does not.

Generate a 2048×1536 solid-color PNG with `UIGraphicsImageRenderer`, pass it through the production `RecipeImageDecoder`, and assert the decoded image's largest pixel dimension is exactly 1024. This pins the real ImageIO path rather than only the injected decoder seam.

- [ ] **Step 2: Regenerate and confirm red**

```bash
xcodegen generate --spec SimmerSmith/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests/RecipeImageLoaderTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected: compile failure because the loader types are absent.

- [ ] **Step 3: Implement request and presentation state**

```swift
struct RecipeImageRequestID: Hashable {
    let recipeID: String
    let imageToken: String
    let loaderRevision: Int
}

struct RecipeImagePresentationState {
    private var requestID: RecipeImageRequestID?
    private var epoch = 0
    private var image: UIImage?
    mutating func begin(_ requestID: RecipeImageRequestID?) -> Int {
        epoch &+= 1
        self.requestID = requestID
        image = nil
        return epoch
    }
    mutating func complete(_ image: UIImage?, requestID: RecipeImageRequestID, epoch: Int) {
        guard self.epoch == epoch, self.requestID == requestID else { return }
        self.image = image
    }
    func image(for requestID: RecipeImageRequestID?) -> UIImage? {
        self.requestID == requestID ? image : nil
    }
    func shouldRetry(_ requestID: RecipeImageRequestID?) -> Bool {
        requestID != nil && self.requestID == requestID && image == nil
    }
}
```

- [ ] **Step 4: Implement loader and decoder**

Make `RecipeImageLoader` `@MainActor @Observable`. Store a private `NSCache<NSString, UIImage>` with count limit 40, in-flight tasks keyed by `RecipeImageRequestID`, cached keys grouped by recipe, and observable per-recipe revisions. `image` returns for nil token, checks cache, joins an in-flight task, otherwise stores the task before awaiting fetch/decode at 1024, caches only non-nil output, and clears in-flight state. Before caching a completion, require that the recipe's current revision still equals the request key's revision; an invalidated old task may finish, but it must return nil instead of repopulating stale data. `invalidate` increments only the target revision and removes only its tasks/cache keys.

```swift
enum RecipeImageDecoder {
    static func downsample(_ data: Data, maximumDimension: CGFloat) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maximumDimension),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return nil
            }
            return UIImage(cgImage: image)
        }.value
    }
}
```

- [ ] **Step 5: Verify and commit**

Run the focused command from Step 2; expect PASS. Then:

```bash
git add SimmerSmith/SimmerSmith/Features/Recipes/RecipeImageLoader.swift SimmerSmith/SimmerSmithTests/RecipeImageLoaderTests.swift SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj
git commit -m "feat(recipes): add bounded image loader"
```

### Task 3: Repository wiring and shared rendering

**Files:**
- Modify: `SimmerSmith/SimmerSmithTests/RecipeMemoryLiveUpdateTests.swift`
- Modify: `SimmerSmith/SimmerSmith/Data/RecipeRepository.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/Recipes/RecipeHeaderImage.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/Recipes/RecipeDetailView.swift`

**Interfaces:**
- Consumes: Task 1's mapper parameter and Task 2's loader/presentation types.
- Produces: revisioned local summaries and photo-over-fallback rendering through all existing shared callers.

- [ ] **Step 1: Write the failing repository test**

In a real `HouseholdSession`, save two `RecipeDraft`s, set both images, capture tokens, wait two milliseconds, replace only the first image, and assert its token changed while the second stayed equal.

```swift
let firstToken = try #require(repo.recipes.first { $0.recipeId == firstID }?.imageUrl)
let secondToken = try #require(repo.recipes.first { $0.recipeId == secondID }?.imageUrl)
try await Task.sleep(for: .milliseconds(2))
repo.setImage(firstID, Data([3]), mime: "image/jpeg")
#expect(repo.recipes.first { $0.recipeId == firstID }?.imageUrl != firstToken)
#expect(repo.recipes.first { $0.recipeId == secondID }?.imageUrl == secondToken)
```

- [ ] **Step 2: Confirm red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests/RecipeMemoryLiveUpdateTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected: token assertion failure because reload supplies only presence.

- [ ] **Step 3: Pass image metadata into the mapper**

Index image records by record name in `RecipeRepository.reload()`, look up `rimg:<recipeID>`, and pass:

```swift
let summary = RecipeRecordMapper.recipe(
    from: recipeValue,
    ingredients: ingredients,
    steps: steps,
    hasImage: imageRecord != nil,
    imageGeneratedAt: imageRecord?["generatedAt"] as? Date)
```

Do not decode the CKAsset; metadata may exist before bytes download.

- [ ] **Step 4: Add AppState ownership**

```swift
@ObservationIgnored
lazy var recipeImageLoader = RecipeImageLoader { [weak self] recipeID in
    guard let self else { throw CancellationError() }
    return try await self.fetchRecipeImageBytes(recipeID: recipeID)
}
```

Keep it internally assignable for app-host tests.

- [ ] **Step 5: Restore rendering**

In `RecipeHeaderImage`, inject `AppState`, add `var isDecorative = true`, keep the current illustration as a private fallback, hold `RecipeImagePresentationState`, and derive request identity from recipe ID, non-nil `imageUrl`, and loader revision. Layer a resizable `Image(uiImage:)` over the fallback using the existing `contentMode`, with an opacity transition and a short ease-in-out animation so the already-visible fallback never flashes away. Use `.task(id:)` plus an epoch-guarded load, and retry on `recipeRepository?.storeGeneration` only while unresolved. Keep the existing loading overlay above both layers. Hide decorative callers from accessibility; label the detail visual `"\(recipe.name) recipe image"` by passing `isDecorative: false` only from `RecipeDetailView`.

```swift
private func load(_ requestID: RecipeImageRequestID?) async {
    let epoch = presentation.begin(requestID)
    guard let requestID else { return }
    let image = await appState.recipeImageLoader.image(
        recipeID: requestID.recipeID,
        imageToken: requestID.imageToken)
    guard !Task.isCancelled else { return }
    presentation.complete(image, requestID: requestID, epoch: epoch)
}
```

- [ ] **Step 6: Verify and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests/RecipeMemoryLiveUpdateTests -only-testing:SimmerSmithTests/RecipeImageLoaderTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
git add SimmerSmith/SimmerSmith/Data/RecipeRepository.swift SimmerSmith/SimmerSmith/App/AppState.swift SimmerSmith/SimmerSmith/Features/Recipes/RecipeHeaderImage.swift SimmerSmith/SimmerSmith/Features/Recipes/RecipeDetailView.swift SimmerSmith/SimmerSmithTests/RecipeMemoryLiveUpdateTests.swift
git commit -m "feat(recipes): render stored recipe photos"
```

Expected: tests and build PASS; card/list geometry is unchanged.

### Task 4: Mutation invalidation and controls

**Files:**
- Create: `SimmerSmith/SimmerSmithTests/RecipeImageMutationTests.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/Recipes/RecipeDetailView.swift`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `recipeImageLoader.invalidate(recipeID:)`.
- Produces: successful legacy mutations refresh one image; failure preserves the cache/revision.

- [ ] **Step 1: Write failing mutation tests**

Create a serialized suite with a private `URLProtocol` table keyed by method/path, an in-memory settings store/model container, minimum valid `RecipeSummary` JSON, and an injected no-op loader.

```swift
@Test func successfulLegacyImageMutationsInvalidateTheRecipe() async throws {
    let fixture = try RecipeImageMutationFixture(statusCode: 200)
    try await fixture.appState.regenerateRecipeImage(recipeID: "R1")
    #expect(fixture.appState.recipeImageLoader.revision(for: "R1") == 1)
    try await fixture.appState.uploadRecipeImage(recipeID: "R1", imageData: Data([1]))
    #expect(fixture.appState.recipeImageLoader.revision(for: "R1") == 2)
    try await fixture.appState.deleteRecipeImage(recipeID: "R1")
    #expect(fixture.appState.recipeImageLoader.revision(for: "R1") == 3)
    #expect(fixture.appState.recipeImageLoader.revision(for: "R2") == 0)
}

@Test func failedLegacyImageMutationDoesNotInvalidate() async throws {
    let fixture = try RecipeImageMutationFixture(statusCode: 500)
    await #expect(throws: (any Error).self) {
        try await fixture.appState.uploadRecipeImage(recipeID: "R1", imageData: Data([1]))
    }
    #expect(fixture.appState.recipeImageLoader.revision(for: "R1") == 0)
}
```

- [ ] **Step 2: Regenerate and confirm red**

```bash
xcodegen generate --spec SimmerSmith/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests/RecipeImageMutationTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected: revision assertions fail.

- [ ] **Step 3: Invalidate only after fallback success**

After each fallback regenerate/upload/delete await and local cache update, add:

```swift
recipeImageLoader.invalidate(recipeID: recipeID)
```

Do not invalidate inside CloudKit branches; their reload changes the generated-at token or removes it. Errors exit before invalidation.

- [ ] **Step 4: Restore per-recipe controls**

Restore the previously shipped `Regenerate image`, `Use my own photo`, and conditional destructive `Remove image` menu actions using the existing state, sheet, confirmation, methods, and error toast. Leave Settings' bulk “Generate missing images” action hidden; this phase does not restore a spending/backfill surface.

- [ ] **Step 5: Verify and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests/RecipeImageMutationTests -only-testing:SimmerSmithTests/RecipeImageLoaderTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
git add SimmerSmith/SimmerSmith/App/AppState+Recipes.swift SimmerSmith/SimmerSmith/Features/Recipes/RecipeDetailView.swift SimmerSmith/SimmerSmithTests/RecipeImageMutationTests.swift SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj
git commit -m "feat(recipes): refresh photos after image changes"
```

Expected: tests and build PASS.

### Task 5: Full verification and handoff

**Files:**
- Modify: `.docs/ai/current-state.md`
- Modify: `.docs/ai/phases/recipe-photo-rendering-spec.md`
- Create: `.docs/ai/phases/recipe-photo-rendering-report.md`

**Interfaces:**
- Consumes: all implementation commits.
- Produces: clean feature branch, machine evidence, and an explicit human UI gate; no merge/release.

- [ ] **Step 1: Run full verification**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithCloudKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: both package suites PASS, `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`, no diff-check output.

- [ ] **Step 2: Record evidence**

Set spec status to `implemented; awaiting human UI verification`. Write the report with branch/commits, changed behavior, exact command results, bulk-backfill-hidden confirmation, build-174/main untouched confirmation, and the five human checks: all shared surfaces, no-photo fallback, rapid scrolling, replace/remove, offline relaunch. Update current state to completed machine phases plus one `[?]` human verification item, preserving build-174 blockers verbatim.

- [ ] **Step 3: Commit and inspect final state**

```bash
git add .docs/ai/current-state.md .docs/ai/phases/recipe-photo-rendering-spec.md .docs/ai/phases/recipe-photo-rendering-report.md
git commit -m "docs(ai): report recipe photo rendering"
git status --short --branch
git log --oneline --decorate -6
```

Expected: clean `codex/recipe-photo-rendering`; no merge, push, build cut, or upload.
