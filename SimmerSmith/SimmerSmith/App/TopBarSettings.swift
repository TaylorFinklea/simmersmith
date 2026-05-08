import Foundation

/// Build 68 — per-tab top-bar primary action.
///
/// The top-bar layout (everywhere except Week, which is excluded by
/// design — its sparkle is per-day inline) is:
///
///     [...existing leading + middle items...]  [primary]  [✨ sparkle]
///
/// `TopBarPage` enumerates each tab; each page exposes a list of
/// available primary actions plus its default. Selection is stored in
/// `UserDefaults` and surfaced in Settings → "Top bar" so the user can
/// override per-tab.
enum TopBarPage: String, CaseIterable, Identifiable, Sendable {
    case week
    case forge
    case grocery
    case pantry
    case events
    case smith

    var id: String { rawValue }

    /// Human-readable label for Settings (lowercase Caveat-friendly).
    var displayLabel: String {
        switch self {
        case .week: return "Week"
        case .forge: return "Forge"
        case .grocery: return "Grocery"
        case .pantry: return "Pantry"
        case .events: return "Events"
        case .smith: return "Smith"
        }
    }

    /// Available primary-action options for this page. The "natural"
    /// action goes first (and is the default).
    var availableActions: [TopBarPrimaryAction] {
        switch self {
        case .week:
            return [.sparkle, .quickAdd, .refresh]
        case .forge:
            return [.add, .sparkle, .search, .filter, .gallery]
        case .grocery:
            return [.add, .sparkle, .refresh, .regenerate, .review]
        case .pantry:
            return [.add, .sparkle, .refresh]
        case .events:
            return [.add, .sparkle]
        case .smith:
            return [.newChat, .sparkle]
        }
    }

    var defaultAction: TopBarPrimaryAction {
        availableActions.first!
    }
}

/// All possible primary-action choices. Not every action applies to
/// every page — `TopBarPage.availableActions` filters down per tab.
enum TopBarPrimaryAction: String, CaseIterable, Codable, Sendable {
    case add
    case sparkle
    case filter
    case gallery
    case refresh
    case regenerate
    case review
    case newChat
    case quickAdd
    case search

    var settingsLabel: String {
        switch self {
        case .add: return "Add"
        case .sparkle: return "Ask the Smith"
        case .filter: return "Filter"
        case .gallery: return "Gallery toggle"
        case .refresh: return "Refresh"
        case .regenerate: return "Regenerate from meals"
        case .review: return "Review queue"
        case .newChat: return "New chat"
        case .quickAdd: return "Quick add meal"
        case .search: return "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .add: return "plus.circle.fill"
        case .sparkle: return "sparkles"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .gallery: return "square.grid.2x2"
        case .refresh: return "arrow.clockwise"
        case .regenerate: return "arrow.triangle.2.circlepath"
        case .review: return "list.bullet.clipboard"
        case .newChat: return "square.and.pencil"
        case .quickAdd: return "plus"
        case .search: return "magnifyingglass"
        }
    }
}
