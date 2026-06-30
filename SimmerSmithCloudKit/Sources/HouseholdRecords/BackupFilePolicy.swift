import Foundation

// SP-C backup/restore — pure file-naming + retention policy (no file I/O), so it's host-testable.
// Filenames sort lexically == chronologically, so "keep the newest N" is a sort + drop.
public enum BackupFilePolicy {
    public static let prefix = "backup-"
    public static let ext = "json"

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)   // UTC so names sort + parse deterministically
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    public static func filename(for date: Date) -> String {
        "\(prefix)\(stampFormatter.string(from: date)).\(ext)"
    }

    public static func date(fromFilename name: String) -> Date? {
        guard name.hasPrefix(prefix), name.hasSuffix(".\(ext)") else { return nil }
        let stamp = name.dropFirst(prefix.count).dropLast(ext.count + 1)
        return stampFormatter.date(from: String(stamp))
    }

    /// The filenames to DELETE so that only the newest `keepLast` remain (by name = chronological).
    public static func toPrune(_ filenames: [String], keepLast: Int) -> [String] {
        let backups = filenames
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".\(ext)") }
            .sorted(by: >)   // newest first
        guard backups.count > keepLast else { return [] }
        return Array(backups.dropFirst(max(keepLast, 0)))
    }
}
