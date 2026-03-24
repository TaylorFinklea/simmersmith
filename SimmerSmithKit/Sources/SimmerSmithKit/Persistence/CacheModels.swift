import Foundation
import SwiftData

@Model
public final class CachedProfileSnapshotRecord {
    @Attribute(.unique) public var key: String
    public var updatedAt: Date
    public var savedAt: Date
    public var payload: Data

    public init(key: String = "profile", updatedAt: Date, savedAt: Date = .now, payload: Data) {
        self.key = key
        self.updatedAt = updatedAt
        self.savedAt = savedAt
        self.payload = payload
    }
}

@Model
public final class CachedWeekSnapshotRecord {
    @Attribute(.unique) public var key: String
    public var updatedAt: Date
    public var savedAt: Date
    public var payload: Data

    public init(key: String = "current-week", updatedAt: Date, savedAt: Date = .now, payload: Data) {
        self.key = key
        self.updatedAt = updatedAt
        self.savedAt = savedAt
        self.payload = payload
    }
}

@Model
public final class CachedRecipesSnapshotRecord {
    @Attribute(.unique) public var key: String
    public var updatedAt: Date
    public var savedAt: Date
    public var payload: Data

    public init(key: String = "recipes", updatedAt: Date, savedAt: Date = .now, payload: Data) {
        self.key = key
        self.updatedAt = updatedAt
        self.savedAt = savedAt
        self.payload = payload
    }
}

@Model
public final class CachedRecipeMetadataRecord {
    @Attribute(.unique) public var key: String
    public var updatedAt: Date
    public var savedAt: Date
    public var payload: Data

    public init(key: String = "recipe-metadata", updatedAt: Date, savedAt: Date = .now, payload: Data) {
        self.key = key
        self.updatedAt = updatedAt
        self.savedAt = savedAt
        self.payload = payload
    }
}

@Model
public final class CachedExportsSnapshotRecord {
    @Attribute(.unique) public var key: String
    public var updatedAt: Date
    public var savedAt: Date
    public var payload: Data

    public init(key: String, updatedAt: Date, savedAt: Date = .now, payload: Data) {
        self.key = key
        self.updatedAt = updatedAt
        self.savedAt = savedAt
        self.payload = payload
    }
}

@Model
public final class CachedGroceryCheckState {
    @Attribute(.unique) public var groceryItemID: String
    public var isChecked: Bool
    public var updatedAt: Date

    public init(groceryItemID: String, isChecked: Bool, updatedAt: Date = .now) {
        self.groceryItemID = groceryItemID
        self.isChecked = isChecked
        self.updatedAt = updatedAt
    }
}
