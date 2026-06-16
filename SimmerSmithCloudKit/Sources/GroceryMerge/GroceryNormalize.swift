import Foundation

// Verbatim port of app/services/grocery.py normalize_name + normalize_unit + UNIT_MAP. Used by
// the event↔week match key (EventMergeEngine) so the on-device match exactly mirrors the server.
public enum GroceryNormalize {

    /// grocery.py:75-80. lower → "&"→" and " → strip non [a-z0-9 ] → collapse whitespace.
    public static func name(_ value: String) -> String {
        var cleaned = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "&", with: " and ")
        let scalars = cleaned.unicodeScalars.map { scalar -> Character in
            let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == " "
            return ok ? Character(scalar) : " "
        }
        return String(scalars).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    /// grocery.py:83-85. normalize_name then UNIT_MAP alias.
    public static func unit(_ value: String) -> String {
        let text = name(value)
        return unitMap[text] ?? text
    }

    static let unitMap: [String: String] = [
        "count": "ct", "counts": "ct", "ct": "ct",
        "each": "ea", "ea": "ea", "egg": "ea", "eggs": "ea",
        "pound": "lb", "pounds": "lb", "lb": "lb", "lbs": "lb",
        "ounce": "oz", "ounces": "oz", "oz": "oz",
        "fluid ounce": "fl oz", "fluid ounces": "fl oz", "fl oz": "fl oz",
        "gallon": "gal", "gallons": "gal", "gal": "gal",
        "cup": "cup", "cups": "cup",
        "tablespoon": "tbsp", "tablespoons": "tbsp", "tbsp": "tbsp",
        "teaspoon": "tsp", "teaspoons": "tsp", "tsp": "tsp",
        "package": "pkg", "packages": "pkg", "pkg": "pkg",
        "can": "can", "cans": "can",
        "bag": "bag", "bags": "bag",
        "bunch": "bunch", "bunches": "bunch",
        "clove": "clove", "cloves": "clove",
        "slice": "slice", "slices": "slice",
    ]
}
