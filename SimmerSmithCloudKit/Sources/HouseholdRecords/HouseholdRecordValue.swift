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

// Explicit Codable so the scalar KIND is preserved across a backup round-trip — a Date stays a
// Date (ISO8601 under the backup encoder), a Bool stays a Bool, etc. (auto-synthesis for an
// associated-value enum would still work, but pinning the format keeps backups stable).
extension ScalarValue: Codable {
    private enum Kind: String, Codable { case string, int, double, date, bool }
    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .string: self = .string(try c.decode(String.self, forKey: .value))
        case .int:    self = .int(try c.decode(Int.self, forKey: .value))
        case .double: self = .double(try c.decode(Double.self, forKey: .value))
        case .date:   self = .date(try c.decode(Date.self, forKey: .value))
        case .bool:   self = .bool(try c.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v): try c.encode(Kind.string, forKey: .kind); try c.encode(v, forKey: .value)
        case .int(let v):    try c.encode(Kind.int, forKey: .kind);    try c.encode(v, forKey: .value)
        case .double(let v): try c.encode(Kind.double, forKey: .kind); try c.encode(v, forKey: .value)
        case .date(let v):   try c.encode(Kind.date, forKey: .kind);   try c.encode(v, forKey: .value)
        case .bool(let v):   try c.encode(Kind.bool, forKey: .kind);   try c.encode(v, forKey: .value)
        }
    }
}

public struct HouseholdRecordValue: Equatable, Codable {
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
