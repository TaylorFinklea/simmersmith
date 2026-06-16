import Foundation

// Generates the CKDSL (CloudKit schema language) for the 2b record types FROM the manifest,
// so the deployed schema and the codec can't drift. The output is appended to
// phase0-schema.ckdb; the user validates + deploys it with the management token.

public extension HouseholdRecordType {
    /// CKDSL `RECORD TYPE` block for this type, matching phase0-schema.ckdb's idiom.
    func ckdsl() -> String {
        var lines: [String] = ["    RECORD TYPE \(recordTypeName) ("]
        var body: [String] = []
        for f in fields {
            var decl = "        \(f.name) \(Self.dslType(f.type))"
            if f.queryable { decl += " QUERYABLE" }
            if f.sortable { decl += " SORTABLE" }
            body.append(decl)
        }
        for r in refs {
            switch r.kind {
            case .cascadeParent, .setNullInZone:
                // CKReference. Parent refs are implicitly queryable — do not mark.
                body.append("        \(r.name) REFERENCE")
            case .crossDBString:
                // A plain String recordName key (cross-DB / not-yet-defined target).
                body.append("        \(r.name) STRING")
            }
        }
        body.append("        GRANT WRITE TO \"_creator\"")
        body.append("        GRANT READ, CREATE TO \"_icloud\"")
        lines.append(body.joined(separator: ",\n"))
        lines.append("    );")
        return lines.joined(separator: "\n")
    }

    /// All 2b blocks, in manifest order, ready to append to the cumulative .ckdb.
    static func allCKDSL() -> String {
        allCases.map { $0.ckdsl() }.joined(separator: "\n\n")
    }

    private static func dslType(_ t: CKFieldType) -> String {
        switch t {
        case .string: return "STRING"
        case .int, .bool: return "INT64"   // Bool stored as INT64 0/1
        case .double: return "DOUBLE"
        case .date: return "TIMESTAMP"
        }
    }
}
