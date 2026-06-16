#if canImport(CloudKit)
import CloudKit
import Foundation

// Mechanical CKRecord ↔ HouseholdRecordValue glue, driven by the HouseholdRecordType manifest.
// All the branching (Bool→INT64, date→TIMESTAMP, cascade .deleteSelf vs SET-NULL .none vs
// cross-DB String) is the manifest's; this just applies it. Verified on-sim via the DEBUG
// round-trip; the manifest classification is pinned by headless tests.

public enum HouseholdRecordCodec {

    /// Encode a value into a CKRecord in the given zone. Reference fields with no target are
    /// left absent (= null). Cross-DB refs encode as plain String keys (never CKReferences).
    public static func encode(_ value: HouseholdRecordValue, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: value.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: value.type.recordTypeName, recordID: recordID)

        let fieldTypes = Dictionary(uniqueKeysWithValues: value.type.fields.map { ($0.name, $0.type) })
        for (name, scalar) in value.scalars {
            guard fieldTypes[name] != nil else { continue }   // ignore unknown fields
            record[name] = ckValue(for: scalar)
        }

        let refKinds = Dictionary(uniqueKeysWithValues: value.type.refs.map { ($0.name, $0.kind) })
        for (name, target) in value.refs {
            guard let kind = refKinds[name] else { continue }
            switch kind {
            case .crossDBString:
                record[name] = target as CKRecordValue
            case .setNullInZone:
                record[name] = CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: target, zoneID: zoneID), action: .none)
            case .cascadeParent:
                record[name] = CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: target, zoneID: zoneID), action: .deleteSelf)
            }
        }
        return record
    }

    /// Decode a fetched CKRecord back into a value using the manifest for type info.
    public static func decode(_ record: CKRecord, as type: HouseholdRecordType) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]
        for field in type.fields {
            guard let raw = record[field.name] else { continue }
            switch field.type {
            case .string: if let v = raw as? String { scalars[field.name] = .string(v) }
            case .int:    if let v = raw as? Int { scalars[field.name] = .int(v) }
            case .double: if let v = raw as? Double { scalars[field.name] = .double(v) }
            case .date:   if let v = raw as? Date { scalars[field.name] = .date(v) }
            case .bool:   if let v = raw as? Int { scalars[field.name] = .bool(v != 0) }
            }
        }
        var refs: [String: String] = [:]
        for ref in type.refs {
            switch ref.kind {
            case .crossDBString:
                if let v = record[ref.name] as? String { refs[ref.name] = v }
            case .setNullInZone, .cascadeParent:
                if let reference = record[ref.name] as? CKRecord.Reference {
                    refs[ref.name] = reference.recordID.recordName
                }
            }
        }
        return HouseholdRecordValue(type: type, recordName: record.recordID.recordName,
                                    scalars: scalars, refs: refs)
    }

    private static func ckValue(for scalar: ScalarValue) -> CKRecordValue {
        switch scalar {
        case .string(let v): return v as CKRecordValue
        case .int(let v): return v as CKRecordValue
        case .double(let v): return v as CKRecordValue
        case .date(let v): return v as CKRecordValue
        case .bool(let v): return (v ? 1 : 0) as CKRecordValue   // Bool → INT64
        }
    }
}
#endif
