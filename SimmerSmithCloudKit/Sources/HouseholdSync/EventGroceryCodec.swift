#if canImport(CloudKit)
import CloudKit
import Foundation
import GroceryMerge

// SP-A Phase 5 Layer A — CKRecord ↔ EventGroceryItem (the event-side contribution pointing
// back into a week's GroceryItem). Mirrors GroceryCodec. The merge-relevant fields only — the
// ingredient-identity expansion needed to CREATE event rows (merge_event_into_week) lands at
// Layer C; this codec carries the thin merger subset. `eventQuantity` here is THIS event row's
// contribution (distinct from week GroceryItem.eventQuantity, the cross-event accumulator).
public enum EventGroceryCodec {
    public static let recordType = "EventGroceryItem"

    public static func makeRecord(_ item: EventGroceryItem, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: recordType,
                              recordID: CKRecord.ID(recordName: item.recordName, zoneID: zoneID))
        encode(item, into: record)
        return record
    }

    public static func encode(_ item: EventGroceryItem, into record: CKRecord) {
        // merged_into_* are SET-NULL soft pointers → plain String keys, never CKReferences.
        record["mergedIntoGroceryItemID"] = item.mergedIntoGroceryItemID as CKRecordValue?
        record["mergedIntoWeekID"] = item.mergedIntoWeekID as CKRecordValue?
        record["eventQuantity"] = item.eventQuantity as CKRecordValue?
        record["modifiedAtClock"] = item.modifiedAt as CKRecordValue
    }

    public static func decode(_ record: CKRecord) -> EventGroceryItem {
        EventGroceryItem(
            recordName: record.recordID.recordName,
            mergedIntoGroceryItemID: record["mergedIntoGroceryItemID"] as? String,
            mergedIntoWeekID: record["mergedIntoWeekID"] as? String,
            eventQuantity: record["eventQuantity"] as? Double,
            modifiedAt: record["modifiedAtClock"] as? Int ?? 0
        )
    }
}
#endif
