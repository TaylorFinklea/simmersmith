#if canImport(CloudKit)
import CloudKit
import Testing
@testable import CloudKitProvisioning

private func publicCatalogRow() -> CatalogRow {
    let record = CKRecord(
        recordType: "IngredientVariation",
        recordID: CKRecord.ID(recordName: "variation-olive-oil")
    )
    record["normalizedName"] = "olive oil" as CKRecordValue
    record["name"] = "Olive Oil" as CKRecordValue
    let baseID = CKRecord.ID(recordName: "base-olive-oil")
    record["baseIngredient"] = CKRecord.Reference(recordID: baseID, action: .none)
    return CatalogRow(record)
}

private func publicBaseRow(
    recordName: String,
    normalizedName: String,
    submissionStatus: String = "approved",
    active: Bool = true
) -> CatalogRow {
    let record = CKRecord(
        recordType: "BaseIngredient",
        recordID: CKRecord.ID(recordName: recordName)
    )
    record["normalizedName"] = normalizedName as CKRecordValue
    record["name"] = normalizedName.capitalized as CKRecordValue
    record["submissionStatus"] = submissionStatus as CKRecordValue
    record["active"] = active as CKRecordValue
    return CatalogRow(record)
}

private final class PublicCatalogStub: @unchecked Sendable {
    enum StubError: Error { case missingRecord }

    let rowsByType: [String: [CatalogRow]]
    let rowsByID: [String: CatalogRow]

    init(rows: [CatalogRow]) {
        rowsByType = Dictionary(grouping: rows, by: \.recordType)
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.recordName, $0) })
    }

    func query(recordType: String, predicate: NSPredicate) -> [CatalogRow] {
        let rows = rowsByType[recordType] ?? []
        if recordType == "BaseIngredient" {
            return rows.filter {
                predicate.evaluate(with: ["normalizedName": $0.normalizedName])
            }
        }
        if recordType == "IngredientVariation" {
            return rows.filter { row in
                guard let base = row.reference("baseIngredient") else { return false }
                let reference = CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: base.recordName), action: .none
                )
                return predicate.evaluate(with: ["baseIngredient": reference])
            }
        }
        return rows
    }

    func fetch(recordID: CKRecord.ID) throws -> CatalogRow {
        guard let row = rowsByID[recordID.recordName] else { throw StubError.missingRecord }
        return row
    }
}

private actor PublicCatalogCallRecorder {
    struct QueryCall: Equatable {
        let recordType: String
        let limit: Int
    }

    private(set) var queries: [QueryCall] = []
    private(set) var fetchIDs: [String] = []

    func recordQuery(recordType: String, limit: Int) {
        queries.append(QueryCall(recordType: recordType, limit: limit))
    }

    func recordFetch(_ recordID: CKRecord.ID) {
        fetchIDs.append(recordID.recordName)
    }

    func snapshot() -> (queries: [QueryCall], fetchIDs: [String]) {
        (queries, fetchIDs)
    }
}

private func publicVariationRow(
    recordName: String,
    normalizedName: String,
    baseIngredientID: String,
    active: Bool = true
) -> CatalogRow {
    let record = CKRecord(
        recordType: "IngredientVariation",
        recordID: CKRecord.ID(recordName: recordName)
    )
    record["normalizedName"] = normalizedName as CKRecordValue
    record["name"] = normalizedName.capitalized as CKRecordValue
    record["active"] = active as CKRecordValue
    record["baseIngredient"] = CKRecord.Reference(
        recordID: CKRecord.ID(recordName: baseIngredientID), action: .none
    )
    return CatalogRow(record)
}

@Test("catalog rows retain identity and searchable fields")
func projectsCatalogIdentityAndSearchFields() {
    let row = publicCatalogRow()

    #expect(row.recordName == "variation-olive-oil")
    #expect(row.recordType == "IngredientVariation")
    #expect(row.normalizedName == "olive oil")
    #expect(row.name == "Olive Oil")
}

@Test("catalog rows project the variation base-ingredient reference")
func projectsBaseIngredientReference() {
    let row = publicCatalogRow()

    #expect(row.reference("baseIngredient")?.recordName == "base-olive-oil")
    #expect(row.references["baseIngredient"]?.recordName == "base-olive-oil")
}

@Test("catalog rows retain boolean status values for client-side filtering")
func projectsBooleanStatusValues() {
    let record = CKRecord(recordType: "BaseIngredient", recordID: CKRecord.ID(recordName: "inactive"))
    record["normalizedName"] = "inactive" as CKRecordValue
    record["active"] = false as CKRecordValue

    #expect(CatalogRow(record).number("active") == 0)
}

@Test("PUBLIC base search uses CloudKit-supported case-sensitive prefix predicates")
func buildsSupportedBaseSearchPredicates() {
    let browse = PublicCatalogReader.baseSearchPredicate(query: "   ")
    #expect(browse.evaluate(with: ["normalizedName": "olive oil"]))
    #expect(!browse.evaluate(with: ["normalizedName": ""]))

    let search = PublicCatalogReader.baseSearchPredicate(query: "  Olive ")
    #expect(search.evaluate(with: ["normalizedName": "olive oil"]))
    #expect(!search.evaluate(with: ["normalizedName": "canola oil"]))
    #expect(!search.predicateFormat.contains("[cd]"))
}

@Test("PUBLIC base search filters ownership state, sorts deterministically, and limits")
func filtersAndLimitsPublicBaseRows() {
    let rows = [
        publicBaseRow(recordName: "z", normalizedName: "zucchini"),
        publicBaseRow(recordName: "b", normalizedName: "apple"),
        publicBaseRow(recordName: "a", normalizedName: "apple"),
        publicBaseRow(recordName: "inactive", normalizedName: "banana", active: false),
        publicBaseRow(recordName: "private", normalizedName: "carrot", submissionStatus: "household_only"),
    ]

    let result = PublicCatalogReader.approvedActiveBaseRows(rows, limit: 2)

    #expect(result.map(\.recordName) == ["a", "b"])
}


@Test("PUBLIC reader searches and browses approved rows through an injected transport")
func searchesAndBrowsesWithInjectedTransport() async {
    let stub = PublicCatalogStub(rows: [
        publicBaseRow(recordName: "olive", normalizedName: "olive oil"),
        publicBaseRow(recordName: "onion", normalizedName: "onion"),
        publicBaseRow(recordName: "private", normalizedName: "olive salt", submissionStatus: "household_only"),
    ])
    let recorder = PublicCatalogCallRecorder()
    let reader = PublicCatalogReader(
        queryRows: { type, predicate, limit in
            await recorder.recordQuery(recordType: type, limit: limit)
            return Array(stub.query(recordType: type, predicate: predicate).prefix(limit))
        },
        fetchRow: { id in
            await recorder.recordFetch(id)
            return try stub.fetch(recordID: id)
        }
    )

    let search = await reader.searchBaseIngredients(query: "olive", limit: 20)
    let browse = await reader.browseBaseIngredients(limit: 1)

    #expect(search.map(\.recordName) == ["olive"])
    #expect(browse.map(\.recordName) == ["olive"])
    let calls = await recorder.snapshot()
    #expect(calls.queries == [
        .init(recordType: "BaseIngredient", limit: 40),
        .init(recordType: "BaseIngredient", limit: 2),
    ])
    #expect(calls.fetchIDs.isEmpty)
}

@Test("PUBLIC reader resolves record IDs and lists only active variations")
func resolvesIDsAndListsVariationsWithInjectedTransport() async throws {
    let stub = PublicCatalogStub(rows: [
        publicBaseRow(recordName: "base-olive", normalizedName: "olive oil"),
        publicVariationRow(
            recordName: "variation-b", normalizedName: "olive oil b", baseIngredientID: "base-olive"
        ),
        publicVariationRow(
            recordName: "variation-a", normalizedName: "olive oil a", baseIngredientID: "base-olive"
        ),
        publicVariationRow(
            recordName: "variation-dead", normalizedName: "olive oil c", baseIngredientID: "base-olive", active: false
        ),
    ])
    let recorder = PublicCatalogCallRecorder()
    let reader = PublicCatalogReader(
        queryRows: { type, predicate, limit in
            await recorder.recordQuery(recordType: type, limit: limit)
            return Array(stub.query(recordType: type, predicate: predicate).prefix(limit))
        },
        fetchRow: { id in
            await recorder.recordFetch(id)
            return try stub.fetch(recordID: id)
        }
    )

    let base = await reader.resolveBaseIngredient(recordName: "base-olive")
    let variation = await reader.resolveIngredientVariation(recordName: "variation-a")
    let beforeVariations = await recorder.snapshot()
    let variations = await reader.fetchIngredientVariations(baseIngredientID: "base-olive", limit: 10)
    let afterVariations = await recorder.snapshot()
    let trustedVariations = await reader.fetchIngredientVariations(
        approvedActiveBase: try #require(base), limit: 10
    )
    let afterTrustedVariations = await recorder.snapshot()

    #expect(base?.recordName == "base-olive")
    #expect(variation?.recordName == "variation-a")
    #expect(variations.map(\.recordName) == ["variation-a", "variation-b"])
    #expect(afterVariations.fetchIDs == beforeVariations.fetchIDs + ["base-olive"])
    #expect(afterVariations.queries.last == .init(recordType: "IngredientVariation", limit: 20))
    #expect(trustedVariations.map(\.recordName) == ["variation-a", "variation-b"])
    #expect(afterTrustedVariations.fetchIDs == afterVariations.fetchIDs)
}

@Test("PUBLIC variation lookup rejects inactive and unapproved parent IDs")
func variationLookupGuardsParentVisibility() async {
    let stub = PublicCatalogStub(rows: [
        publicBaseRow(recordName: "inactive-base", normalizedName: "inactive", active: false),
        publicBaseRow(
            recordName: "private-base", normalizedName: "private",
            submissionStatus: "household_only"
        ),
        publicVariationRow(
            recordName: "inactive-variation", normalizedName: "inactive variation",
            baseIngredientID: "inactive-base"
        ),
        publicVariationRow(
            recordName: "private-variation", normalizedName: "private variation",
            baseIngredientID: "private-base"
        ),
    ])
    let recorder = PublicCatalogCallRecorder()
    let reader = PublicCatalogReader(
        queryRows: { type, predicate, limit in
            await recorder.recordQuery(recordType: type, limit: limit)
            return Array(stub.query(recordType: type, predicate: predicate).prefix(limit))
        },
        fetchRow: { id in
            await recorder.recordFetch(id)
            return try stub.fetch(recordID: id)
        }
    )

    let inactive = await reader.fetchIngredientVariations(baseIngredientID: "inactive-base")
    let unapproved = await reader.fetchIngredientVariations(baseIngredientID: "private-base")
    let calls = await recorder.snapshot()

    #expect(inactive.isEmpty)
    #expect(unapproved.isEmpty)
    #expect(calls.fetchIDs == ["inactive-base", "private-base"])
    #expect(calls.queries.isEmpty)
}
#endif
