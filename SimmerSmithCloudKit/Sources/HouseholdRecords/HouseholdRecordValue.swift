import Foundation

// Pure transport value for a household record — what the codec encodes to / decodes from a
// CKRecord, driven by the HouseholdRecordType manifest. Generic on purpose: 2b records are
// inert LWW pass-through, so a single field-bag value (not 12 bespoke structs) carries them.
// Typed domain structs arrive when the app wires these to its models (Phase 7).

public enum ScalarValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case date(Date)
    case bool(Bool)
}

public struct HouseholdRecordValue: Equatable {
    public let type: HouseholdRecordType
    public let recordName: String
    /// Scalar field name → value. Omitted fields are absent (optional columns stay absent).
    public var scalars: [String: ScalarValue]
    /// Reference field name → target recordName. A key mapped to nil encodes as absent (null).
    public var refs: [String: String]

    public init(type: HouseholdRecordType, recordName: String,
                scalars: [String: ScalarValue] = [:], refs: [String: String] = [:]) {
        self.type = type
        self.recordName = recordName
        self.scalars = scalars
        self.refs = refs
    }
}
