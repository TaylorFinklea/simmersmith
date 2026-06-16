#if canImport(CloudKit)
import CloudKit
import Foundation
import GroceryMerge

// SP-A Phase 4 — CKRecord ↔ GroceryItem bridge for the sticky field-merge. Keeps the
// merge-relevant + identity fields; the logical clocks (createdAt/modifiedAt/check.at) are
// stored as INT64 so ordering is exact (app-wiring maps real timestamps → clocks at Phase 7).
// `encode(into:)` writes onto an EXISTING record so a merge can preserve the server change tag.
public enum GroceryCodec {
    public static let recordType = "GroceryItem"

    public static func makeRecord(_ item: GroceryItem, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: recordType,
                              recordID: CKRecord.ID(recordName: item.recordName, zoneID: zoneID))
        encode(item, into: record)
        return record
    }

    /// Write every field onto `record` (system fields / change tag preserved).
    public static func encode(_ item: GroceryItem, into record: CKRecord) {
        func setOpt(_ key: String, _ value: CKRecordValue?) {
            if let value { record[key] = value } else { record[key] = nil }
        }
        record["weekID"] = item.weekID as CKRecordValue
        record["resolutionStatus"] = item.resolutionStatus as CKRecordValue
        record["unit"] = item.unit as CKRecordValue
        record["quantityText"] = item.quantityText as CKRecordValue
        record["normalizedName"] = item.normalizedName as CKRecordValue
        record["ingredientName"] = item.ingredientName as CKRecordValue
        record["category"] = item.category as CKRecordValue
        record["notes"] = item.notes as CKRecordValue
        record["sourceMeals"] = item.sourceMeals as CKRecordValue
        record["reviewFlag"] = item.reviewFlag as CKRecordValue
        record["storeLabel"] = item.storeLabel as CKRecordValue
        setOpt("baseIngredientID", item.baseIngredientID as CKRecordValue?)
        setOpt("ingredientVariationID", item.ingredientVariationID as CKRecordValue?)
        setOpt("totalQuantity", item.totalQuantity as CKRecordValue?)
        setOpt("quantityOverride", item.quantityOverride as CKRecordValue?)
        setOpt("unitOverride", item.unitOverride as CKRecordValue?)
        setOpt("notesOverride", item.notesOverride as CKRecordValue?)
        setOpt("eventQuantity", item.eventQuantity as CKRecordValue?)
        record["isUserAdded"] = (item.isUserAdded ? 1 : 0) as CKRecordValue
        record["isUserRemoved"] = (item.isUserRemoved ? 1 : 0) as CKRecordValue
        record["isChecked"] = (item.check.isChecked ? 1 : 0) as CKRecordValue
        setOpt("checkedBy", item.check.by as CKRecordValue?)
        record["checkedAtClock"] = item.check.at as CKRecordValue
        record["createdAtClock"] = item.createdAt as CKRecordValue
        record["modifiedAtClock"] = item.modifiedAt as CKRecordValue
    }

    public static func decode(_ record: CKRecord) -> GroceryItem {
        GroceryItem(
            recordName: record.recordID.recordName,
            weekID: record["weekID"] as? String ?? "",
            baseIngredientID: record["baseIngredientID"] as? String,
            ingredientVariationID: record["ingredientVariationID"] as? String,
            resolutionStatus: record["resolutionStatus"] as? String ?? "unresolved",
            unit: record["unit"] as? String ?? "",
            quantityText: record["quantityText"] as? String ?? "",
            normalizedName: record["normalizedName"] as? String ?? "",
            ingredientName: record["ingredientName"] as? String ?? "",
            category: record["category"] as? String ?? "",
            totalQuantity: record["totalQuantity"] as? Double,
            notes: record["notes"] as? String ?? "",
            sourceMeals: record["sourceMeals"] as? String ?? "",
            reviewFlag: record["reviewFlag"] as? String ?? "",
            storeLabel: record["storeLabel"] as? String ?? "",
            isUserAdded: (record["isUserAdded"] as? Int ?? 0) != 0,
            isUserRemoved: (record["isUserRemoved"] as? Int ?? 0) != 0,
            quantityOverride: record["quantityOverride"] as? Double,
            unitOverride: record["unitOverride"] as? String,
            notesOverride: record["notesOverride"] as? String,
            check: CheckState(isChecked: (record["isChecked"] as? Int ?? 0) != 0,
                              at: record["checkedAtClock"] as? Int ?? 0,
                              by: record["checkedBy"] as? String),
            eventQuantity: record["eventQuantity"] as? Double,
            createdAt: record["createdAtClock"] as? Int ?? 0,
            modifiedAt: record["modifiedAtClock"] as? Int ?? 0
        )
    }
}
#endif
