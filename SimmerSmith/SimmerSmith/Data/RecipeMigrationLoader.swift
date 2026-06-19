#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import HouseholdRecords
import HouseholdSync
import SimmerSmithKit

// SP-C Task 6 — first-launch recipe migration Fly→CloudKit.
//
// Pulls all recipes (+ ingredients/steps), metadata (cuisines/tags/units as
// ManagedListItems), and per-recipe images from the Fly backend and writes them
// into the household CloudKit zone via the sync engine. Idempotent: a
// `MigrationReceipt` stamped under scope "recipes" short-circuits every
// subsequent call — safe to call on every launch.
//
// Key decisions:
//  1. Uses RecipeRecordMapper.records(from:) directly rather than routing
//     through HouseholdMigrationRunner.migrate(scope:export:). The runner
//     expects raw snake_case [String:Any] dicts (Postgres row format), but
//     apiClient.fetchRecipes() returns decoded RecipeSummary structs. Building
//     those dicts by inverting the .convertFromSnakeCase decoder would be
//     fragile; RecipeRecordMapper is the canonical type-safe path already
//     verified on-device in Task 1–4 and used by RecipeRepository.
//     The receipt gate + stamping logic mirrors the runner verbatim (same
//     receipt recordName, same write-last-for-crash-safety invariant).
//  2. ManagedListItems (cuisines/tags/units from GET /api/recipes/metadata)
//     are written directly as HouseholdRecordValue with .managedListItem type
//     — the manifest already handles their deterministic recordName
//     (kind+name). RecipeTemplates are not migrated here (PUBLIC catalog scope).
//  3. Images are migrated per recipe after all record writes, before draining,
//     using the existing fetchRecipeImageBytes endpoint. A missing or 404 image
//     is skipped (not fatal — the recipe record is still migrated).
//  4. After all saves: engine.sendUntilDrained() pushes to CloudKit.

private let recipeMigrationScope = "recipes"

/// Pull recipes + metadata + images from Fly and write them into the household
/// CloudKit zone. No-op if the migration receipt is already present locally.
/// Must be called after `session.start()` (zone provisioned + first fetch done)
/// and before the first `recipeRepository.reload()` so new installs hydrate
/// CloudKit before the first read.
@MainActor
func migrateRecipesIfNeeded(
    session: HouseholdSession,
    apiClient: SimmerSmithAPIClient
) async {
    // Gate: skip if already migrated on this device (or another device synced
    // the receipt into this device's local store during session.start()).
    let receiptID = CKRecord.ID(
        recordName: HouseholdMigrationRunner.receiptRecordName(scope: recipeMigrationScope),
        zoneID: session.zoneID
    )
    guard session.store.record(for: receiptID) == nil else { return }

    // Fetch recipes (list endpoint includes ingredients + steps).
    let recipes: [RecipeSummary]
    do {
        recipes = try await apiClient.fetchRecipes(includeArchived: true)
    } catch {
        // Network unavailable or Fly down — skip migration this launch.
        // The receipt is not stamped so migration will retry next launch.
        return
    }

    // Fetch metadata (cuisines / tags / units → ManagedListItems).
    let metadata: RecipeMetadata?
    do {
        metadata = try await apiClient.fetchRecipeMetadata()
    } catch {
        metadata = nil  // not fatal; recipe records still migrate
    }

    // Write managed list items (cuisines, tags, units).
    if let metadata {
        let allItems = metadata.cuisines + metadata.tags + metadata.units
        for item in allItems {
            let row = HouseholdRecordValue(
                type: .managedListItem,
                recordName: RecordNames.managedListItem(kind: item.kind, name: item.name),
                scalars: [
                    "kind": .string(item.kind),
                    "name": .string(item.name),
                    "normalizedName": .string(item.normalizedName),
                    "updatedAt": .date(item.updatedAt),
                ],
                refs: [:]
            )
            session.engine.save(HouseholdRecordCodec.encode(row, zoneID: session.zoneID))
        }
    }

    // Write recipe + child records via the canonical RecipeRecordMapper.
    for recipe in recipes {
        let mapped = RecipeRecordMapper.records(from: recipe)
        session.engine.save(HouseholdRecordCodec.encode(mapped.recipe, zoneID: session.zoneID))
        for ing in mapped.ingredients {
            session.engine.save(HouseholdRecordCodec.encode(ing, zoneID: session.zoneID))
        }
        for step in mapped.steps {
            session.engine.save(HouseholdRecordCodec.encode(step, zoneID: session.zoneID))
        }
    }

    // Migrate images: one Fly round-trip per recipe that has an imageUrl.
    // A 404 / network error for one image is skipped — the receipt is still
    // stamped so images for failed recipes are absent (the view shows the
    // gradient placeholder). This matches the existing RecipeRepository image
    // write path (repo.setImage) without reimplementing it.
    for recipe in recipes where recipe.imageUrl != nil {
        guard let imageData = try? await apiClient.fetchRecipeImageBytes(recipeID: recipe.recipeId),
              !imageData.isEmpty else { continue }
        let recipeImage = RecipeImage(
            recipeID: recipe.recipeId,
            mimeType: "image/png",
            prompt: "",
            generatedAt: recipe.updatedAt,
            imageData: imageData
        )
        guard let imageRecord = try? RecipeImageCodec.makeRecord(recipeImage, zoneID: session.zoneID) else {
            continue
        }
        session.engine.save(imageRecord)
    }

    // Stamp the receipt LAST — mirrors HouseholdMigrationRunner.migrate() crash-safety
    // invariant: a crash mid-import leaves no receipt, so the retry reprocesses everything
    // (the engine's PK-preserving upserts make the retry idempotent via serverRecordChanged).
    let receipt = CKRecord(recordType: HouseholdMigrationRunner.receiptType, recordID: receiptID)
    receipt["scope"] = recipeMigrationScope as CKRecordValue
    session.engine.save(receipt)

    // Drain: push all saves to CloudKit. The engine's automaticSync also fires in the
    // background, but an explicit drain here ensures the write reaches the server
    // before the first recipeRepository.reload() reads the store.
    try? await session.engine.sendUntilDrained()
}
#endif
