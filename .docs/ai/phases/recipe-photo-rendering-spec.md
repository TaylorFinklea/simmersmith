# Recipe Photo Rendering — Design Spec

Date: 2026-08-12
Roadmap item: `xwb` stage 2
Status: approved design; awaiting written-spec review

## Outcome

Restore recipe photos as the primary visual in recipe detail and every existing recipe card/list
surface. Preserve the current editorial gradient and meal icon as the immediate, missing-asset,
decode-failure, and not-yet-downloaded fallback. Once photo rendering is verified, restore the
existing regenerate, user-upload, and remove-image controls.

This work proceeds on `codex/recipe-photo-rendering`, based on build-174 commit `72c4033`, while the
owner and participant device gates continue against the unchanged TestFlight build.

## Product behavior

- A recipe with no `imageUrl` renders the current illustration and performs no image read.
- A recipe with `imageUrl` renders the illustration immediately, then fades the photo into the same
  shape and crop already defined by each caller.
- Passive list/card loading shows no spinner and never replaces the illustration with an empty box.
- Detail-view regenerate retains its existing loading overlay. Upload and regenerate replace the
  visible photo after success; remove returns immediately to the illustration.
- Missing, corrupt, or not-yet-downloaded bytes are non-fatal. The illustration remains visible and
  the loader retries a missing asset when the recipe repository reports a later store generation.
- Image failures do not surface global sync errors, block recipe navigation, or trigger AI work.
- Accessibility identifies the visual as the recipe image when a photo is shown; decorative list
  contexts may continue to hide the visual when the surrounding card already names the recipe.

## Architecture

### Shared loader

Add one AppState-owned, observable recipe-image loader. It is UI-local infrastructure: it does not
enter `RecipeSummary`, CloudKit schemas, the repository record model, or persistence.

The loader:

- obtains raw bytes only through the existing `AppState.fetchRecipeImageBytes(recipeID:)` boundary;
- coalesces concurrent requests for the same recipe and image token;
- downsamples and decodes away from the main actor to a maximum 1024-pixel dimension;
- keeps a bounded decoded-image `NSCache` with a 40-image count limit;
- exposes targeted invalidation so legacy-path mutations refresh one recipe without evicting
  unrelated images;
- never retains raw image bytes after decode; and
- treats cancellation, missing assets, and decode failures as a nil result.

The cache key is recipe ID plus the `imageUrl` token and loader-owned revision. Extend the existing
CloudKit summary mapping so its local-only `ckasset://` token includes `RecipeImage.generatedAt`.
This uses an existing record field and changes no CloudKit schema or persisted recipe data. A remote
replacement therefore changes only the affected recipe token; a legacy-path mutation also performs
targeted loader invalidation because remote URL revision behavior is not controlled here.

### View integration

`RecipeHeaderImage` remains the single visual component used by detail, hero, compact, card, and
list-row surfaces. Split its current gradient/icon composition into a small fallback subview, then
layer the loaded photo above it. Keep view-owned request state private and use task identity so an
older request cannot overwrite a newer recipe/image-token request.

Follow the existing environment-injected `AppState` pattern used by recipe memory photos. The view
reads the image token and the repository store generation needed to retry a missing asset; it does
not reload an already decoded photo for unrelated store generations.

### Mutation integration

After a successful legacy-path regenerate, upload, or remove operation, invalidate only that recipe
in the shared loader. CloudKit mutations reload summaries with a new generated-at token or nil token.
Do not invalidate on a failed mutation. Backfill reloads the summaries once after the batch commits.

Restore the existing recipe-detail image menu only after the loader and invalidation tests pass. No
new image-generation entry point, provider, setting, or automatic generation behavior is added.

## Data flow

1. `RecipeHeaderImage` receives a `RecipeSummary`.
2. Nil `imageUrl` selects the illustration without fetching.
3. Non-nil `imageUrl` requests the recipe/image-token pair from the shared loader.
4. The loader returns a cached decoded image, joins an in-flight request, or fetches existing bytes.
5. Bytes are downsampled off-main and the decoded result is cached.
6. The view publishes the result only if its recipe/image-token request is still current.
7. A missing result retains the illustration; a later repository generation retries only while the
   view still lacks a photo.
8. Image mutations invalidate the affected recipe so visible views request the new revision.

## Error and resource boundaries

- The fallback is always renderable and never depends on CloudKit, network, or image decoding.
- Cancellation is normal during fast scrolling and must not be logged as an error.
- Corrupt data does not poison the cache. A later invalidation or store-generation retry may recover.
- The loader bounds decoded memory and coalesces work; it does not create a second disk cache.
- No image bytes, prompts, provider keys, or recipe data leave existing AppState/CloudKit boundaries.
- No changes touch onboarding lifecycle, normal-mode mutation durability, household authority, or the
  build-174 release configuration being tested.

## Tests and acceptance

Use red-green TDD for the loader and display policy.

- Nil `imageUrl` makes zero fetches and selects the illustration.
- Valid bytes decode into a photo; invalid bytes return nil and retain the illustration.
- Two concurrent requests for one recipe/image token perform one fetch/decode.
- A cache hit avoids another fetch; the decoded-image cache is configured with a 40-image limit.
- Invalidating recipe A refetches A and does not evict or refetch recipe B.
- Changing an image record's `generatedAt` changes only that recipe's CloudKit `imageUrl` token.
- A missing asset retries after repository generation advances; a successfully loaded immutable asset
  does not reload on unrelated store generations.
- Regenerate/upload/remove invalidate only after successful mutation.
- A stale request cannot overwrite a newer recipe/image-token result.
- Existing card and detail callers continue to compile without layout changes.
- Focused app-host tests, full `SimmerSmithTests`, generic simulator build, and `git diff --check` pass.

## Human verification

On a data-rich simulator or device:

1. Recipe list, hero, compact, and detail surfaces show existing CloudKit photos with correct crops.
2. A recipe without a photo retains the current gradient and meal icon.
3. Rapid scrolling remains smooth and does not flash empty rectangles.
4. Regenerate and upload replace the visible photo; remove returns to the illustration.
5. Relaunch offline still renders locally available photo assets and safely falls back for unavailable
   assets.

This UI verification is for the feature branch and does not replace build 174's onboarding or
owner/participant crash-durability gates.

## Non-goals

- No new photo-generation policy, provider selection, automatic backfill, or spending behavior.
- No CloudKit schema, record codec, repository persistence, backend, Fly.io, or web change; only the
  local summary token derived from the existing `generatedAt` field changes.
- No redesign of recipe cards, detail geometry, illustration palettes, or meal icons.
- No photo editor, crop UI, progressive network download, disk-cache layer, or prefetch scheduler.
- No push, TestFlight upload, build-number bump, or merge to local `main` before verification.
