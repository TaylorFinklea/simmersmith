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
        guard recordType == "BaseIngredient" else { return rows }
        return rows.filter {
            predicate.evaluate(with: ["normalizedName": $0.normalizedName])
        }
    }

    func fetch(recordID: CKRecord.ID) throws -> CatalogRow {
        guard let row = rowsByID[recordID.recordName] else { throw StubError.missingRecord }
        return row
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
    let reader = PublicCatalogReader(
        queryRows: { type, predicate in stub.query(recordType: type, predicate: predicate) },
        fetchRow: { id in try stub.fetch(recordID: id) }
    )

    let search = await reader.searchBaseIngredients(query: "olive", limit: 20)
    let browse = await reader.browseBaseIngredients(limit: 1)

    #expect(search.map(\.recordName) == ["olive"])
    #expect(browse.map(\.recordName) == ["olive"])
}

@Test("PUBLIC reader resolves record IDs and lists only active variations")
func resolvesIDsAndListsVariationsWithInjectedTransport() async {
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
    let reader = PublicCatalogReader(
        queryRows: { type, predicate in stub.query(recordType: type, predicate: predicate) },
        fetchRow: { id in try stub.fetch(recordID: id) }
    )

    let base = await reader.resolveBaseIngredient(recordName: "base-olive")
    let variation = await reader.resolveIngredientVariation(recordName: "variation-a")
    let variations = await reader.fetchIngredientVariations(baseIngredientID: "base-olive", limit: 10)

    #expect(base?.recordName == "base-olive")
    #expect(variation?.recordName == "variation-a")
    #expect(variations.map(\.recordName) == ["variation-a", "variation-b"])
}
#endif
