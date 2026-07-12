import CloudKit
import GroceryMerge
import HouseholdRecords
import HouseholdSync
import Testing

@testable import SimmerSmith

@MainActor
@Suite(.serialized)
struct IngredientRepositoryTests {
    @Test
    func baseIngredientCreateListDetailUpdateArchiveUsesTheHouseholdStore() throws {
        let session = HouseholdSession(householdID: "ingredient-base-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)

        let created = try repository.createBaseIngredient(
            name: "  Green & Yellow Peppers!  ",
            category: " Produce ",
            defaultUnit: "Tablespoons",
            notes: "  crisp  ",
            provisional: true,
            nutritionReferenceAmount: 100,
            calories: 30
        )

        #expect(created.name == "Green & Yellow Peppers!")
        #expect(created.normalizedName == "green and yellow peppers")
        #expect(created.category == "Produce")
        #expect(created.defaultUnit == "tbsp")
        #expect(created.notes == "crisp")
        #expect(created.householdId == session.householdID)
        #expect(created.submissionStatus == "household_only")
        #expect(repository.searchBaseIngredients(query: "YELLOW peppers").map(\.id) == [created.id])
        #expect(repository.searchBaseIngredients(provisionalOnly: true).map(\.id) == [created.id])

        let variation = try repository.createIngredientVariation(
            baseIngredientID: created.id,
            name: " Market Peppers "
        )
        seedUsageRecords(baseIngredientID: created.id, session: session)

        let detail = try repository.fetchBaseIngredientDetail(baseIngredientID: created.id)
        #expect(detail.ingredient.variationCount == 1)
        #expect(detail.ingredient.recipeUsageCount == 1)
        #expect(detail.ingredient.groceryUsageCount == 1)
        #expect(detail.variations.map(\.id) == [variation.id])
        #expect(detail.preference == nil)
        #expect(detail.usage.linkedRecipeIds == ["recipe-1"])
        #expect(detail.usage.linkedRecipeNames == ["Pepper Pasta"])
        #expect(detail.usage.linkedGroceryItemIds == ["grocery-1"])
        #expect(detail.usage.linkedGroceryNames == ["Peppers"])

        let recordID = CKRecord.ID(recordName: created.id, zoneID: session.zoneID)
        let originalRecord = try #require(session.store.record(for: recordID))
        let originalCreatedAt = try #require(originalRecord["createdAt"] as? Date)
        originalRecord["serverOwnedMarker"] = "keep-me" as CKRecordValue
        session.engine.save(originalRecord)

        let updated = try repository.updateBaseIngredient(
            baseIngredientID: created.id,
            name: " Sweet Peppers ",
            normalizedName: " Custom PEPPER Key! ",
            category: "Vegetables",
            defaultUnit: "Pounds",
            notes: " updated "
        )

        #expect(updated.id == created.id)
        #expect(updated.name == "Sweet Peppers")
        #expect(updated.normalizedName == "custom pepper key")
        #expect(updated.defaultUnit == "lb")
        let updatedRecord = try #require(session.store.record(for: recordID))
        #expect(updatedRecord["serverOwnedMarker"] as? String == "keep-me")
        #expect(updatedRecord["createdAt"] as? Date == originalCreatedAt)
        #expect(updatedRecord["nutritionReferenceAmount"] == nil)
        #expect(updatedRecord["calories"] == nil)

        let archived = try repository.archiveBaseIngredient(baseIngredientID: created.id)

        #expect(archived.active == false)
        #expect(archived.archivedAt != nil)
        #expect(repository.searchBaseIngredients().isEmpty)
        #expect(repository.searchBaseIngredients(includeArchived: true).map(\.id) == [created.id])
    }

    @Test
    func variationCreateListUpdateArchiveNormalizesAndEncodesCascadeParent() throws {
        let session = HouseholdSession(householdID: "ingredient-variation-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let base = try repository.createBaseIngredient(name: "Tomatoes")

        let created = try repository.createIngredientVariation(
            baseIngredientID: base.id,
            name: "  Mom's & Pop's Tomatoes!  ",
            brand: "  Garden Co.  ",
            packageSizeAmount: 2,
            packageSizeUnit: "Pounds",
            countPerPackage: 4,
            nutritionReferenceAmount: 3,
            nutritionReferenceUnit: "Ounces",
            calories: 25
        )

        #expect(created.name == "Mom's & Pop's Tomatoes!")
        #expect(created.normalizedName == "mom s and pop s tomatoes")
        #expect(created.brand == "Garden Co.")
        #expect(created.packageSizeUnit == "lb")
        #expect(created.nutritionReferenceUnit == "oz")
        #expect(repository.fetchIngredientVariations(baseIngredientID: base.id).map(\.id) == [created.id])

        let recordID = CKRecord.ID(recordName: created.id, zoneID: session.zoneID)
        let record = try #require(session.store.record(for: recordID))
        let parent = try #require(record["baseIngredient"] as? CKRecord.Reference)
        #expect(parent.recordID.recordName == base.id)
        #expect(parent.action == .deleteSelf)

        let updated = try repository.updateIngredientVariation(
            ingredientVariationID: created.id,
            baseIngredientID: base.id,
            name: " Crushed Tomatoes ",
            normalizedName: " Crushed TOMATOES!!! ",
            brand: " Pantry Brand ",
            packageSizeUnit: "Cans"
        )

        #expect(updated.id == created.id)
        #expect(updated.normalizedName == "crushed tomatoes")
        #expect(updated.brand == "Pantry Brand")
        #expect(updated.packageSizeUnit == "can")
        let clearedRecord = try #require(session.store.record(for: recordID))
        #expect(clearedRecord["packageSizeAmount"] == nil)
        #expect(clearedRecord["countPerPackage"] == nil)
        #expect(clearedRecord["nutritionReferenceAmount"] == nil)
        #expect(clearedRecord["calories"] == nil)

        let archived = try repository.archiveIngredientVariation(ingredientVariationID: created.id)

        #expect(archived.active == false)
        #expect(archived.archivedAt != nil)
        #expect(repository.fetchIngredientVariations(baseIngredientID: base.id).isEmpty)
        #expect(repository.fetchIngredientVariations(baseIngredientID: base.id, includeArchived: true).map(\.id) == [created.id])
    }

    @Test
    func repeatedCreateReusesOnlyActiveHouseholdRecordsWithTheSameNormalizedName() throws {
        let session = HouseholdSession(householdID: "ingredient-idempotent-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)

        let firstBase = try repository.createBaseIngredient(
            name: "Bell Pepper",
            normalizedName: "sweet pepper"
        )
        let repeatedBase = try repository.createBaseIngredient(
            name: "Sweet Pepper",
            normalizedName: " SWEET pepper! "
        )

        #expect(repeatedBase.id == firstBase.id)
        #expect(session.store.records(ofType: HouseholdRecordType.baseIngredient.recordTypeName).count == 1)

        let firstVariation = try repository.createIngredientVariation(
            baseIngredientID: firstBase.id,
            name: "Garden Pepper",
            normalizedName: "garden pepper"
        )
        let repeatedVariation = try repository.createIngredientVariation(
            baseIngredientID: firstBase.id,
            name: "Garden Peppers",
            normalizedName: " GARDEN pepper! "
        )

        #expect(repeatedVariation.id == firstVariation.id)
        #expect(session.store.records(ofType: HouseholdRecordType.ingredientVariation.recordTypeName).count == 1)

        _ = try repository.archiveIngredientVariation(ingredientVariationID: firstVariation.id)
        let replacementVariation = try repository.createIngredientVariation(
            baseIngredientID: firstBase.id,
            name: "Garden Pepper",
            normalizedName: "garden pepper"
        )
        #expect(replacementVariation.id != firstVariation.id)

        _ = try repository.archiveBaseIngredient(baseIngredientID: firstBase.id)
        let replacementBase = try repository.createBaseIngredient(
            name: "Sweet Pepper",
            normalizedName: "sweet pepper"
        )
        #expect(replacementBase.id != firstBase.id)
    }

    @Test
    func householdBaseMergeRepointsUsageAndVariationsWithoutTouchingOtherZones() throws {
        let session = HouseholdSession(householdID: "ingredient-merge-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let source = try repository.createBaseIngredient(name: "Legacy Pepper")
        let target = try repository.createBaseIngredient(name: "Sweet Pepper")
        let sourceVariation = try repository.createIngredientVariation(
            baseIngredientID: source.id,
            name: "Market Pepper"
        )
        seedMergeUsageRecords(
            baseIngredientID: source.id,
            ingredientVariationID: sourceVariation.id,
            prefix: "merge",
            session: session
        )

        let merged = try repository.mergeBaseIngredient(sourceID: source.id, targetID: target.id)

        #expect(merged.id == target.id)
        #expect(merged.active)
        #expect(repository.fetchIngredientVariations(baseIngredientID: target.id).map(\.id) == [sourceVariation.id])

        let sourceDetail = try repository.fetchBaseIngredientDetail(baseIngredientID: source.id)
        #expect(sourceDetail.ingredient.active == false)
        #expect(sourceDetail.ingredient.mergedIntoId == target.id)

        let recipeRecord = try #require(storedRecord("merge-recipe", session: session))
        #expect(recipeRecord["baseIngredientID"] as? String == target.id)
        #expect(recipeRecord["ingredientVariationID"] as? String == sourceVariation.id)
        #expect(recipeRecord["resolutionStatus"] as? String == "resolved")
        #expect(recipeRecord["notes"] as? String == "preserve-merge")
        #expect((recipeRecord["updatedAt"] as? Date) ?? .distantPast > Date(timeIntervalSince1970: 10))

        let eventRecord = try #require(storedRecord("merge-event", session: session))
        #expect(eventRecord["baseIngredientID"] as? String == target.id)
        #expect(eventRecord["ingredientVariationID"] as? String == sourceVariation.id)
        #expect(eventRecord["resolutionStatus"] as? String == "resolved")
        #expect(eventRecord["notes"] as? String == "preserve-merge")
        #expect((eventRecord["updatedAt"] as? Date) ?? .distantPast > Date(timeIntervalSince1970: 11))

        let groceryRecord = try #require(storedRecord("merge-grocery", session: session))
        #expect(groceryRecord["baseIngredientID"] as? String == target.id)
        #expect(groceryRecord["ingredientVariationID"] as? String == sourceVariation.id)
        #expect(groceryRecord["resolutionStatus"] as? String == "resolved")
        #expect(groceryRecord["notes"] as? String == "preserve-merge")
        #expect((groceryRecord["modifiedAtClock"] as? Int) ?? 0 > 41)

        let eventGroceryRecord = try #require(storedRecord("merge-event-grocery", session: session))
        #expect(eventGroceryRecord["baseIngredientID"] as? String == target.id)
        #expect(eventGroceryRecord["ingredientVariationID"] as? String == sourceVariation.id)
        #expect(eventGroceryRecord["resolutionStatus"] as? String == "resolved")
        #expect(eventGroceryRecord["notes"] as? String == "preserve-merge")
        #expect((eventGroceryRecord["modifiedAtClock"] as? Int) ?? 0 > 42)

        let variationRecord = try #require(session.store.record(for: CKRecord.ID(
            recordName: sourceVariation.id,
            zoneID: session.zoneID
        )))
        let parent = try #require(variationRecord["baseIngredient"] as? CKRecord.Reference)
        #expect(parent.recordID.recordName == target.id)
        #expect(parent.action == .deleteSelf)
    }

    @Test
    func householdBaseMergeRejectsSelfMergeAndCycles() throws {
        let session = HouseholdSession(householdID: "ingredient-merge-cycle-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let source = try repository.createBaseIngredient(name: "Source Pepper")
        let target = try repository.createBaseIngredient(name: "Target Pepper")

        #expect(throws: IngredientRepositoryError.mergeWouldCreateCycle) {
            _ = try repository.mergeBaseIngredient(sourceID: source.id, targetID: source.id)
        }

        let bridge = try repository.createBaseIngredient(name: "Bridge Pepper")
        let targetRecord = try #require(storedRecord(target.id, session: session))
        targetRecord["mergedIntoID"] = bridge.id as CKRecordValue
        session.engine.save(targetRecord)
        let bridgeRecord = try #require(storedRecord(bridge.id, session: session))
        bridgeRecord["mergedIntoID"] = source.id as CKRecordValue
        session.engine.save(bridgeRecord)

        #expect(throws: IngredientRepositoryError.mergeWouldCreateCycle) {
            _ = try repository.mergeBaseIngredient(sourceID: source.id, targetID: target.id)
        }
    }

    @Test
    func householdBaseMergeCoalescesDuplicateVariationAndRepointsAllUsageDeterministically() throws {
        let session = HouseholdSession(householdID: "ingredient-merge-duplicate-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let source = try repository.createBaseIngredient(name: "Legacy Tomato")
        let target = try repository.createBaseIngredient(name: "Tomato")
        let sourceVariation = try repository.createIngredientVariation(
            baseIngredientID: source.id,
            name: "Canned Tomato",
            normalizedName: "canned tomato"
        )
        seedVariation(
            id: "target-variation-z",
            baseIngredientID: target.id,
            normalizedName: "canned tomato",
            session: session
        )
        seedVariation(
            id: "target-variation-a",
            baseIngredientID: target.id,
            normalizedName: "canned tomato",
            session: session
        )
        seedMergeUsageRecords(
            baseIngredientID: source.id,
            ingredientVariationID: sourceVariation.id,
            prefix: "duplicate",
            session: session
        )

        _ = try repository.mergeBaseIngredient(sourceID: source.id, targetID: target.id)

        for recordName in ["duplicate-recipe", "duplicate-event", "duplicate-grocery", "duplicate-event-grocery"] {
            let record = try #require(storedRecord(recordName, session: session))
            #expect(record["baseIngredientID"] as? String == target.id)
            #expect(record["ingredientVariationID"] as? String == "target-variation-a")
            #expect(record["notes"] as? String == "preserve-duplicate")
        }
        let sourceVariationRecord = try #require(storedRecord(sourceVariation.id, session: session))
        #expect((sourceVariationRecord["active"] as? Int) == 0)
        #expect(sourceVariationRecord["archivedAt"] as? Date != nil)
        #expect(sourceVariationRecord["mergedIntoID"] as? String == "target-variation-a")
        let parent = try #require(sourceVariationRecord["baseIngredient"] as? CKRecord.Reference)
        #expect(parent.recordID.recordName == target.id)
        #expect(parent.action == .deleteSelf)

        let unselected = try #require(storedRecord("target-variation-z", session: session))
        #expect((unselected["active"] as? Int) == 1)
        #expect(unselected["mergedIntoID"] == nil)
    }

    @Test
    func householdBaseMergeChoosesLowestRecordIDWhenSourceHasDuplicateVariations() throws {
        let session = HouseholdSession(householdID: "ingredient-merge-source-order-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let source = try repository.createBaseIngredient(name: "Legacy Beans")
        let target = try repository.createBaseIngredient(name: "Beans")
        let variationIDs = (0..<16).map { String(format: "source-variation-%02d", $0) }
        for variationID in variationIDs.reversed() {
            seedVariation(
                id: variationID,
                baseIngredientID: source.id,
                normalizedName: "canned beans",
                session: session
            )
        }
        seedMergeUsageRecords(
            baseIngredientID: source.id,
            ingredientVariationID: variationIDs.last!,
            prefix: "source-order",
            session: session
        )

        _ = try repository.mergeBaseIngredient(sourceID: source.id, targetID: target.id)

        #expect(repository.fetchIngredientVariations(baseIngredientID: target.id).map(\.id) == [variationIDs[0]])
        for recordName in ["source-order-recipe", "source-order-event", "source-order-grocery", "source-order-event-grocery"] {
            let record = try #require(storedRecord(recordName, session: session))
            #expect(record["ingredientVariationID"] as? String == variationIDs[0])
        }
        for variationID in variationIDs.dropFirst() {
            let record = try #require(storedRecord(variationID, session: session))
            #expect((record["active"] as? Int) == 0)
            #expect(record["mergedIntoID"] as? String == variationIDs[0])
        }
    }

    @Test
    func householdBaseMergeRejectsMissingAndInactiveEndpoints() throws {
        let session = HouseholdSession(householdID: "ingredient-merge-endpoints-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let active = try repository.createBaseIngredient(name: "Active")
        let inactiveSource = try repository.createBaseIngredient(name: "Inactive Source")
        let inactiveTarget = try repository.createBaseIngredient(name: "Inactive Target")
        _ = try repository.archiveBaseIngredient(baseIngredientID: inactiveSource.id)
        _ = try repository.archiveBaseIngredient(baseIngredientID: inactiveTarget.id)

        #expect(throws: IngredientRepositoryError.baseIngredientNotFound) {
            _ = try repository.mergeBaseIngredient(sourceID: "missing", targetID: active.id)
        }
        #expect(throws: IngredientRepositoryError.baseIngredientNotFound) {
            _ = try repository.mergeBaseIngredient(sourceID: active.id, targetID: "missing")
        }
        #expect(throws: IngredientRepositoryError.baseIngredientNotFound) {
            _ = try repository.mergeBaseIngredient(sourceID: inactiveSource.id, targetID: active.id)
        }
        #expect(throws: IngredientRepositoryError.baseIngredientNotFound) {
            _ = try repository.mergeBaseIngredient(sourceID: active.id, targetID: inactiveTarget.id)
        }
    }

    @Test
    func householdBaseMergeRejectsTargetChainBeyondDepthCap() throws {
        let session = HouseholdSession(householdID: "ingredient-merge-depth-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let source = try repository.createBaseIngredient(name: "Depth Source")
        for index in 0...32 {
            seedBaseIngredient(
                id: "depth-\(index)",
                normalizedName: "depth-\(index)",
                session: session
            )
        }
        for index in 0..<32 {
            let record = try #require(storedRecord("depth-\(index)", session: session))
            record["mergedIntoID"] = "depth-\(index + 1)" as CKRecordValue
            session.engine.save(record)
        }

        #expect(throws: IngredientRepositoryError.mergeWouldCreateCycle) {
            _ = try repository.mergeBaseIngredient(sourceID: source.id, targetID: "depth-0")
        }
    }

    @Test
    func tiedBaseAndVariationNamesSortByStableRecordID() throws {
        let baseSession = HouseholdSession(householdID: "ingredient-base-order-\(UUID().uuidString)")
        let baseRepository = IngredientRepository(session: baseSession)
        let reverseBaseIDs = (1...8).reversed().map { "base-\($0)" }
        for id in reverseBaseIDs {
            seedBaseIngredient(id: id, normalizedName: "normalized-\(id)", session: baseSession)
        }

        #expect(baseRepository.searchBaseIngredients(limit: 20).map(\.id) == reverseBaseIDs.sorted())

        let variationSession = HouseholdSession(householdID: "ingredient-variation-order-\(UUID().uuidString)")
        let variationRepository = IngredientRepository(session: variationSession)
        let parent = try variationRepository.createBaseIngredient(name: "Parent")
        let reverseVariationIDs = (1...8).reversed().map { "variation-\($0)" }
        for id in reverseVariationIDs {
            seedVariation(
                id: id,
                baseIngredientID: parent.id,
                normalizedName: "normalized-\(id)",
                session: variationSession
            )
        }

        #expect(
            variationRepository.fetchIngredientVariations(baseIngredientID: parent.id).map(\.id)
                == reverseVariationIDs.sorted()
        )
    }

    @Test
    func variationUpdatePreservesExistingProvenanceAndOnlyFillsBlanks() throws {
        let session = HouseholdSession(householdID: "ingredient-provenance-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let base = try repository.createBaseIngredient(name: "Beans")
        let sourced = try repository.createIngredientVariation(
            baseIngredientID: base.id,
            name: "Black Beans",
            sourceName: "Original Source",
            sourceRecordID: "original-id",
            sourceURL: "https://original.example/item"
        )

        let omitted = try repository.updateIngredientVariation(
            ingredientVariationID: sourced.id,
            baseIngredientID: base.id,
            name: "Black Beans"
        )
        #expect(omitted.sourceName == "Original Source")
        #expect(omitted.sourceRecordId == "original-id")
        #expect(omitted.sourceUrl == "https://original.example/item")

        let nonOverwriting = try repository.updateIngredientVariation(
            ingredientVariationID: sourced.id,
            baseIngredientID: base.id,
            name: "Black Beans",
            sourceName: "Replacement Source",
            sourceRecordID: "replacement-id",
            sourceURL: "https://replacement.example/item"
        )
        #expect(nonOverwriting.sourceName == "Original Source")
        #expect(nonOverwriting.sourceRecordId == "original-id")
        #expect(nonOverwriting.sourceUrl == "https://original.example/item")

        let blank = try repository.createIngredientVariation(
            baseIngredientID: base.id,
            name: "Pinto Beans"
        )
        let filled = try repository.updateIngredientVariation(
            ingredientVariationID: blank.id,
            baseIngredientID: base.id,
            name: "Pinto Beans",
            sourceName: "Filled Source",
            sourceRecordID: "filled-id",
            sourceURL: "https://filled.example/item"
        )
        #expect(filled.sourceName == "Filled Source")
        #expect(filled.sourceRecordId == "filled-id")
        #expect(filled.sourceUrl == "https://filled.example/item")
    }

    @Test
    func requiredNamesAndMissingIDsThrowSpecificRepositoryErrors() throws {
        let session = HouseholdSession(householdID: "ingredient-errors-\(UUID().uuidString)")
        let repository = IngredientRepository(session: session)
        let base = try repository.createBaseIngredient(name: "Carrots")
        let variation = try repository.createIngredientVariation(baseIngredientID: base.id, name: "Baby Carrots")

        #expect(throws: IngredientRepositoryError.emptyName) {
            _ = try repository.createBaseIngredient(name: " \n ")
        }
        #expect(throws: IngredientRepositoryError.emptyName) {
            _ = try repository.updateBaseIngredient(baseIngredientID: base.id, name: "\t")
        }
        #expect(throws: IngredientRepositoryError.emptyName) {
            _ = try repository.createIngredientVariation(baseIngredientID: base.id, name: " ")
        }
        #expect(throws: IngredientRepositoryError.emptyName) {
            _ = try repository.updateIngredientVariation(
                ingredientVariationID: variation.id,
                baseIngredientID: base.id,
                name: ""
            )
        }

        #expect(throws: IngredientRepositoryError.baseIngredientNotFound) {
            _ = try repository.fetchBaseIngredientDetail(baseIngredientID: "missing-base")
        }
        #expect(throws: IngredientRepositoryError.baseIngredientNotFound) {
            _ = try repository.updateBaseIngredient(baseIngredientID: "missing-base", name: "Missing")
        }
        #expect(throws: IngredientRepositoryError.baseIngredientNotFound) {
            _ = try repository.archiveBaseIngredient(baseIngredientID: "missing-base")
        }
        #expect(throws: IngredientRepositoryError.baseIngredientNotFound) {
            _ = try repository.createIngredientVariation(baseIngredientID: "missing-base", name: "Missing")
        }
        #expect(throws: IngredientRepositoryError.ingredientVariationNotFound) {
            _ = try repository.updateIngredientVariation(
                ingredientVariationID: "missing-variation",
                baseIngredientID: base.id,
                name: "Missing"
            )
        }
        #expect(throws: IngredientRepositoryError.ingredientVariationNotFound) {
            _ = try repository.archiveIngredientVariation(ingredientVariationID: "missing-variation")
        }
    }

    private func seedMergeUsageRecords(
        baseIngredientID: String,
        ingredientVariationID: String,
        prefix: String,
        session: HouseholdSession
    ) {
        let recipeIngredient = HouseholdRecordValue(
            type: .recipeIngredient,
            recordName: "\(prefix)-recipe",
            scalars: [
                "ingredientName": .string("Legacy Ingredient"),
                "normalizedName": .string("legacy ingredient"),
                "notes": .string("preserve-\(prefix)"),
                "resolutionStatus": .string("unresolved"),
                "createdAt": .date(Date(timeIntervalSince1970: 10)),
                "updatedAt": .date(Date(timeIntervalSince1970: 10)),
            ],
            refs: [
                "recipe": "\(prefix)-recipe-parent",
                "baseIngredientID": baseIngredientID,
                "ingredientVariationID": ingredientVariationID,
            ]
        )
        let eventIngredient = HouseholdRecordValue(
            type: .eventMealIngredient,
            recordName: "\(prefix)-event",
            scalars: [
                "ingredientName": .string("Legacy Ingredient"),
                "normalizedName": .string("legacy ingredient"),
                "notes": .string("preserve-\(prefix)"),
                "resolutionStatus": .string("unresolved"),
                "createdAt": .date(Date(timeIntervalSince1970: 11)),
                "updatedAt": .date(Date(timeIntervalSince1970: 11)),
            ],
            refs: [
                "eventMeal": "\(prefix)-event-parent",
                "baseIngredientID": baseIngredientID,
                "ingredientVariationID": ingredientVariationID,
            ]
        )
        let grocery = GroceryItem(
            recordName: "\(prefix)-grocery",
            baseIngredientID: baseIngredientID,
            ingredientVariationID: ingredientVariationID,
            resolutionStatus: "unresolved",
            notes: "preserve-\(prefix)",
            modifiedAt: 41
        )
        let eventGrocery = EventGroceryItem(
            recordName: "\(prefix)-event-grocery",
            baseIngredientID: baseIngredientID,
            ingredientVariationID: ingredientVariationID,
            notes: "preserve-\(prefix)",
            resolutionStatus: "unresolved",
            modifiedAt: 42
        )

        session.engine.save(HouseholdRecordCodec.encode(recipeIngredient, zoneID: session.zoneID))
        session.engine.save(HouseholdRecordCodec.encode(eventIngredient, zoneID: session.zoneID))
        session.engine.save(GroceryCodec.makeRecord(grocery, zoneID: session.zoneID))
        session.engine.save(EventGroceryCodec.makeRecord(eventGrocery, zoneID: session.zoneID))
    }

    private func storedRecord(_ recordName: String, session: HouseholdSession) -> CKRecord? {
        session.store.record(for: CKRecord.ID(recordName: recordName, zoneID: session.zoneID))
    }

    private func seedUsageRecords(baseIngredientID: String, session: HouseholdSession) {
        let recipe = HouseholdRecordValue(
            type: .recipe,
            recordName: "recipe-1",
            scalars: [
                "name": .string("Pepper Pasta"),
                "createdAt": .date(Date(timeIntervalSince1970: 10)),
                "updatedAt": .date(Date(timeIntervalSince1970: 10)),
            ],
            refs: [:]
        )
        let recipeIngredient = HouseholdRecordValue(
            type: .recipeIngredient,
            recordName: "recipe-ingredient-1",
            scalars: [
                "ingredientName": .string("Peppers"),
                "normalizedName": .string("peppers"),
                "createdAt": .date(Date(timeIntervalSince1970: 11)),
                "updatedAt": .date(Date(timeIntervalSince1970: 11)),
            ],
            refs: ["recipe": "recipe-1", "baseIngredientID": baseIngredientID]
        )
        let grocery = CKRecord(
            recordType: GroceryCodec.recordType,
            recordID: CKRecord.ID(recordName: "grocery-1", zoneID: session.zoneID)
        )
        grocery["ingredientName"] = "Peppers" as CKRecordValue
        grocery["baseIngredientID"] = baseIngredientID as CKRecordValue

        session.engine.save(HouseholdRecordCodec.encode(recipe, zoneID: session.zoneID))
        session.engine.save(HouseholdRecordCodec.encode(recipeIngredient, zoneID: session.zoneID))
        session.engine.save(grocery)
    }

    private func seedBaseIngredient(id: String, normalizedName: String, session: HouseholdSession) {
        let value = HouseholdRecordValue(
            type: .baseIngredient,
            recordName: id,
            scalars: [
                "name": .string("Same Name"),
                "normalizedName": .string(normalizedName),
                "submissionStatus": .string("household_only"),
                "provisional": .bool(false),
                "active": .bool(true),
                "createdAt": .date(.distantPast),
                "updatedAt": .date(.distantPast),
            ],
            refs: [:]
        )
        session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
    }

    private func seedVariation(
        id: String,
        baseIngredientID: String,
        normalizedName: String,
        session: HouseholdSession
    ) {
        let value = HouseholdRecordValue(
            type: .ingredientVariation,
            recordName: id,
            scalars: [
                "name": .string("Same Variation"),
                "normalizedName": .string(normalizedName),
                "active": .bool(true),
                "createdAt": .date(.distantPast),
                "updatedAt": .date(.distantPast),
            ],
            refs: ["baseIngredient": baseIngredientID]
        )
        session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
    }
}
