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
// ManagedListItems), per-recipe images, and per-recipe memories (the per-cook
// log, Fly table recipe_memories) from the Fly backend and writes them into
// the household CloudKit zone via the sync engine. Idempotent: a
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
//  3. Images are migrated in parallel (up to 6 concurrent fetches) using
//     withTaskGroup. The fetch + decode is I/O; the engine.save calls happen
//     on the MainActor after all bytes land. Receipt is stamped AFTER images.
//  4. Recipe memories migrate after images: text rows are receipt-blocking
//     (a failed fetch withholds the receipt so the next launch retries);
//     memory photos are best-effort like recipe images.
//  5. After all saves: engine.sendUntilDrained() pushes to CloudKit.

private let recipeMigrationScope = "recipes"
private let imageFetchConcurrency = 6

// MARK: - MIME detection

/// Detect image MIME type from the leading bytes of `data`.
/// Falls back to `image/jpeg` for unknown formats.
private func detectMime(_ data: Data) -> String {
    guard data.count >= 4 else { return "image/jpeg" }
    let b = data.prefix(4)
    // PNG: 0x89 0x50 0x4E 0x47
    if b[b.startIndex] == 0x89 && b[b.startIndex + 1] == 0x50
        && b[b.startIndex + 2] == 0x4E && b[b.startIndex + 3] == 0x47 {
        return "image/png"
    }
    // JPEG: 0xFF 0xD8 0xFF
    if b[b.startIndex] == 0xFF && b[b.startIndex + 1] == 0xD8
        && b[b.startIndex + 2] == 0xFF {
        return "image/jpeg"
    }
    return "image/jpeg"
}

// MARK: - Memory row construction

/// Build the CloudKit row for one migrated Fly memory. Shape mirrors
/// `RecipeRepository.addMemory`: the manifest namePolicy for `.recipeMemory`
/// is `.pk`, so the legacy Fly UUID is carried verbatim as the recordName.
/// Internal (not private) so the app-target test can pin the shape.
func recipeMemoryMigrationRow(recipeID: String, memory: RecipeMemory) -> HouseholdRecordValue {
    HouseholdRecordValue(
        type: .recipeMemory,
        recordName: memory.id,
        scalars: ["body": .string(memory.body), "createdAt": .date(memory.createdAt)],
        refs: ["recipe": recipeID]
    )
}

// MARK: - Migration entry point

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
    guard CachedHouseholdSystemOperationPolicy.allows(
        .migration,
        isCachedBootstrap: session.isCachedBootstrap) else { return }
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
    // Include createdAt to match MetadataRepository.createManagedListItem — the
    // receipt gate prevents re-running so migrated items must carry the field on
    // the first (and only) write.
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
                    "createdAt": .date(item.updatedAt),
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

    // Migrate images in parallel (bounded to `imageFetchConcurrency` in-flight)
    // to avoid serialised O(N×RTT) first-launch cost.
    //
    // The fetch + decode is pure I/O — the work runs off the MainActor inside
    // the group tasks. Only the engine.save calls happen back on MainActor
    // (the save is synchronous + cheap). Receipt is stamped AFTER all images so
    // a mid-image crash leaves no receipt and the next launch retries.
    let recipesWithImages = recipes.filter { $0.imageUrl != nil }
    if !recipesWithImages.isEmpty {
        // Collect (recipeID, imageData) pairs off-actor, cap concurrency.
        let imagePairs: [(recipeID: String, data: Data)] = await withTaskGroup(
            of: (String, Data)?.self
        ) { group in
            var inFlight = 0
            var iterator = recipesWithImages.makeIterator()
            var results: [(String, Data)] = []

            // Seed initial batch.
            while inFlight < imageFetchConcurrency, let recipe = iterator.next() {
                let id = recipe.recipeId
                group.addTask {
                    guard let bytes = try? await apiClient.fetchRecipeImageBytes(recipeID: id),
                          !bytes.isEmpty else { return nil }
                    return (id, bytes)
                }
                inFlight += 1
            }

            // Drain group; replenish from iterator as slots free up.
            for await result in group {
                inFlight -= 1
                if let pair = result {
                    results.append(pair)
                }
                if let next = iterator.next() {
                    let id = next.recipeId
                    group.addTask {
                        guard let bytes = try? await apiClient.fetchRecipeImageBytes(recipeID: id),
                              !bytes.isEmpty else { return nil }
                        return (id, bytes)
                    }
                    inFlight += 1
                }
            }
            return results
        }

        // Save image records on MainActor (engine is not Sendable).
        for (recipeID, imageData) in imagePairs {
            let mime = detectMime(imageData)
            let recipeImage = RecipeImage(
                recipeID: recipeID,
                mimeType: mime,
                prompt: "",
                generatedAt: Date(),
                imageData: imageData
            )
            guard let imageRecord = try? RecipeImageCodec.makeRecord(recipeImage, zoneID: session.zoneID) else {
                continue
            }
            session.engine.save(imageRecord)
        }
    }

    // Migrate recipe memories (the per-cook log, Fly table recipe_memories).
    // Fetches run in a bounded task group mirroring the image group above.
    // A 404 (pre-M15 server or vanished recipe) means "no memories" and maps
    // to .success([]); any other error is a real failure and is tracked so the
    // receipt can be withheld below.
    var memoriesFetchFailed = false
    var fetchedMemories: [(recipeID: String, memory: RecipeMemory)] = []
    if !recipes.isEmpty {
        let memoryResults: [(String, Result<[RecipeMemory], any Error>)] = await withTaskGroup(
            of: (String, Result<[RecipeMemory], any Error>).self
        ) { group in
            var inFlight = 0
            var iterator = recipes.makeIterator()
            var results: [(String, Result<[RecipeMemory], any Error>)] = []

            // Seed initial batch.
            while inFlight < imageFetchConcurrency, let recipe = iterator.next() {
                let id = recipe.recipeId
                group.addTask {
                    do {
                        return (id, .success(try await apiClient.fetchRecipeMemories(recipeID: id)))
                    } catch SimmerSmithAPIError.notFound {
                        return (id, .success([]))
                    } catch {
                        return (id, .failure(error))
                    }
                }
                inFlight += 1
            }

            // Drain group; replenish from iterator as slots free up.
            for await result in group {
                inFlight -= 1
                results.append(result)
                if let next = iterator.next() {
                    let id = next.recipeId
                    group.addTask {
                        do {
                            return (id, .success(try await apiClient.fetchRecipeMemories(recipeID: id)))
                        } catch SimmerSmithAPIError.notFound {
                            return (id, .success([]))
                        } catch {
                            return (id, .failure(error))
                        }
                    }
                    inFlight += 1
                }
            }
            return results
        }

        // Save memory text rows on MainActor (engine is not Sendable). Raw
        // engine.save, not RecipeRepository — this file deliberately bypasses
        // repositories (see header doc).
        for (recipeID, result) in memoryResults {
            switch result {
            case .success(let memories):
                for memory in memories {
                    let row = recipeMemoryMigrationRow(recipeID: recipeID, memory: memory)
                    session.engine.save(HouseholdRecordCodec.encode(row, zoneID: session.zoneID))
                    fetchedMemories.append((recipeID: recipeID, memory: memory))
                }
            case .failure:
                memoriesFetchFailed = true
            }
        }

        // Memory photos: best-effort, second bounded task group (same shape).
        let memoriesWithPhotos = fetchedMemories.filter { $0.memory.photoUrl != nil }
        if !memoriesWithPhotos.isEmpty {
            let photoPairs: [(memory: RecipeMemory, data: Data)] = await withTaskGroup(
                of: (RecipeMemory, Data)?.self
            ) { group in
                var inFlight = 0
                var iterator = memoriesWithPhotos.makeIterator()
                var results: [(RecipeMemory, Data)] = []

                // Seed initial batch.
                while inFlight < imageFetchConcurrency, let item = iterator.next() {
                    let recipeID = item.recipeID
                    let memory = item.memory
                    group.addTask {
                        guard let bytes = try? await apiClient.fetchRecipeMemoryPhotoBytes(
                            recipeID: recipeID, memoryID: memory.id
                        ), !bytes.isEmpty else { return nil }
                        return (memory, bytes)
                    }
                    inFlight += 1
                }

                // Drain group; replenish from iterator as slots free up.
                for await result in group {
                    inFlight -= 1
                    if let pair = result {
                        results.append(pair)
                    }
                    if let next = iterator.next() {
                        let recipeID = next.recipeID
                        let memory = next.memory
                        group.addTask {
                            guard let bytes = try? await apiClient.fetchRecipeMemoryPhotoBytes(
                                recipeID: recipeID, memoryID: memory.id
                            ), !bytes.isEmpty else { return nil }
                            return (memory, bytes)
                        }
                        inFlight += 1
                    }
                }
                return results
            }

            // Save memory photo records on MainActor.
            for (memory, bytes) in photoPairs {
                let mime = detectMime(bytes)
                let image = RecipeMemoryImage(
                    memoryID: memory.id,
                    mimeType: mime,
                    createdAt: memory.createdAt,  // the memory's own timestamp — honest provenance
                    imageData: bytes
                )
                guard let record = try? RecipeMemoryImageCodec.makeRecord(image, zoneID: session.zoneID) else {
                    continue
                }
                session.engine.save(record)
            }
        }
    }

    // RECEIPT-BLOCKING RULE (deliberately different from images): memory TEXT
    // is family cook-history and unrecoverable, unlike photos. If any
    // per-recipe memories fetch failed, everything fetched above is still
    // saved and drained, but the receipt is NOT stamped — the next launch
    // retries the whole migration (idempotent per the crash-safety note
    // below). Photos stay pure best-effort and never block the receipt.
    if memoriesFetchFailed {
        try? await session.engine.sendUntilDrained()
        return
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
