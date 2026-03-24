import Foundation
import SwiftData

@MainActor
public final class SimmerSmithCacheStore {
    private let modelContainer: ModelContainer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        modelContainer: ModelContainer,
        encoder: JSONEncoder = SimmerSmithJSONCoding.makeEncoder(),
        decoder: JSONDecoder = SimmerSmithJSONCoding.makeDecoder()
    ) {
        self.modelContainer = modelContainer
        self.encoder = encoder
        self.decoder = decoder
    }

    public func loadProfile() -> ProfileSnapshot? {
        loadRecord(CachedProfileSnapshotRecord.self, key: "profile", as: ProfileSnapshot.self)
    }

    public func saveProfile(_ profile: ProfileSnapshot) throws {
        try saveRecord(
            CachedProfileSnapshotRecord.self,
            key: "profile",
            updatedAt: profile.updatedAt ?? .now,
            value: profile
        )
    }

    public func loadCurrentWeek() -> WeekSnapshot? {
        loadRecord(CachedWeekSnapshotRecord.self, key: "current-week", as: WeekSnapshot.self)
    }

    public func saveCurrentWeek(_ week: WeekSnapshot) throws {
        try saveRecord(
            CachedWeekSnapshotRecord.self,
            key: "current-week",
            updatedAt: week.updatedAt,
            value: week
        )
    }

    public func loadRecipes() -> [RecipeSummary] {
        loadRecord(CachedRecipesSnapshotRecord.self, key: "recipes", as: [RecipeSummary].self) ?? []
    }

    public func saveRecipes(_ recipes: [RecipeSummary]) throws {
        let updatedAt = recipes.map(\.updatedAt).max() ?? .now
        try saveRecord(
            CachedRecipesSnapshotRecord.self,
            key: "recipes",
            updatedAt: updatedAt,
            value: recipes
        )
    }

    public func loadRecipeMetadata() -> RecipeMetadata? {
        loadRecord(CachedRecipeMetadataRecord.self, key: "recipe-metadata", as: RecipeMetadata.self)
    }

    public func saveRecipeMetadata(_ metadata: RecipeMetadata) throws {
        try saveRecord(
            CachedRecipeMetadataRecord.self,
            key: "recipe-metadata",
            updatedAt: metadata.updatedAt ?? .now,
            value: metadata
        )
    }

    public func loadExports(for weekID: String) -> [ExportRun] {
        loadRecord(CachedExportsSnapshotRecord.self, key: weekID, as: [ExportRun].self) ?? []
    }

    public func saveExports(_ exports: [ExportRun], for weekID: String) throws {
        let updatedAt = exports.map(\.updatedAt).max() ?? .now
        try saveRecord(
            CachedExportsSnapshotRecord.self,
            key: weekID,
            updatedAt: updatedAt,
            value: exports
        )
    }

    public func isChecked(groceryItemID: String) -> Bool {
        let descriptor = FetchDescriptor<CachedGroceryCheckState>(
            predicate: #Predicate { $0.groceryItemID == groceryItemID }
        )
        let context = ModelContext(modelContainer)
        return (try? context.fetch(descriptor).first?.isChecked) ?? false
    }

    public func setChecked(_ checked: Bool, groceryItemID: String) throws {
        let descriptor = FetchDescriptor<CachedGroceryCheckState>(
            predicate: #Predicate { $0.groceryItemID == groceryItemID }
        )
        let context = ModelContext(modelContainer)
        if let existing = try context.fetch(descriptor).first {
            existing.isChecked = checked
            existing.updatedAt = .now
        } else {
            context.insert(CachedGroceryCheckState(groceryItemID: groceryItemID, isChecked: checked))
        }
        try context.save()
    }

    public func clearAll() throws {
        let context = ModelContext(modelContainer)
        try context.delete(model: CachedProfileSnapshotRecord.self)
        try context.delete(model: CachedWeekSnapshotRecord.self)
        try context.delete(model: CachedRecipesSnapshotRecord.self)
        try context.delete(model: CachedRecipeMetadataRecord.self)
        try context.delete(model: CachedExportsSnapshotRecord.self)
        try context.delete(model: CachedGroceryCheckState.self)
        try context.save()
    }

    private func loadRecord<Record: PersistentModel, Value: Decodable>(
        _ type: Record.Type,
        key: String,
        as valueType: Value.Type
    ) -> Value? where Record: AnyObject {
        let context = ModelContext(modelContainer)
        if type == CachedProfileSnapshotRecord.self {
            let descriptor = FetchDescriptor<CachedProfileSnapshotRecord>(
                predicate: #Predicate { $0.key == key }
            )
            guard let record = try? context.fetch(descriptor).first else { return nil }
            return try? decoder.decode(Value.self, from: record.payload)
        }
        if type == CachedWeekSnapshotRecord.self {
            let descriptor = FetchDescriptor<CachedWeekSnapshotRecord>(
                predicate: #Predicate { $0.key == key }
            )
            guard let record = try? context.fetch(descriptor).first else { return nil }
            return try? decoder.decode(Value.self, from: record.payload)
        }
        if type == CachedRecipesSnapshotRecord.self {
            let descriptor = FetchDescriptor<CachedRecipesSnapshotRecord>(
                predicate: #Predicate { $0.key == key }
            )
            guard let record = try? context.fetch(descriptor).first else { return nil }
            return try? decoder.decode(Value.self, from: record.payload)
        }
        if type == CachedRecipeMetadataRecord.self {
            let descriptor = FetchDescriptor<CachedRecipeMetadataRecord>(
                predicate: #Predicate { $0.key == key }
            )
            guard let record = try? context.fetch(descriptor).first else { return nil }
            return try? decoder.decode(Value.self, from: record.payload)
        }
        if type == CachedExportsSnapshotRecord.self {
            let descriptor = FetchDescriptor<CachedExportsSnapshotRecord>(
                predicate: #Predicate { $0.key == key }
            )
            guard let record = try? context.fetch(descriptor).first else { return nil }
            return try? decoder.decode(Value.self, from: record.payload)
        }
        return nil
    }

    private func saveRecord<Value: Encodable>(
        _ type: CachedProfileSnapshotRecord.Type,
        key: String,
        updatedAt: Date,
        value: Value
    ) throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedProfileSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        let payload = try encoder.encode(value)
        if let existing = try context.fetch(descriptor).first {
            existing.updatedAt = updatedAt
            existing.savedAt = .now
            existing.payload = payload
        } else {
            context.insert(CachedProfileSnapshotRecord(key: key, updatedAt: updatedAt, payload: payload))
        }
        try context.save()
    }

    private func saveRecord<Value: Encodable>(
        _ type: CachedWeekSnapshotRecord.Type,
        key: String,
        updatedAt: Date,
        value: Value
    ) throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedWeekSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        let payload = try encoder.encode(value)
        if let existing = try context.fetch(descriptor).first {
            existing.updatedAt = updatedAt
            existing.savedAt = .now
            existing.payload = payload
        } else {
            context.insert(CachedWeekSnapshotRecord(key: key, updatedAt: updatedAt, payload: payload))
        }
        try context.save()
    }

    private func saveRecord<Value: Encodable>(
        _ type: CachedRecipesSnapshotRecord.Type,
        key: String,
        updatedAt: Date,
        value: Value
    ) throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedRecipesSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        let payload = try encoder.encode(value)
        if let existing = try context.fetch(descriptor).first {
            existing.updatedAt = updatedAt
            existing.savedAt = .now
            existing.payload = payload
        } else {
            context.insert(CachedRecipesSnapshotRecord(key: key, updatedAt: updatedAt, payload: payload))
        }
        try context.save()
    }

    private func saveRecord<Value: Encodable>(
        _ type: CachedRecipeMetadataRecord.Type,
        key: String,
        updatedAt: Date,
        value: Value
    ) throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedRecipeMetadataRecord>(
            predicate: #Predicate { $0.key == key }
        )
        let payload = try encoder.encode(value)
        if let existing = try context.fetch(descriptor).first {
            existing.updatedAt = updatedAt
            existing.savedAt = .now
            existing.payload = payload
        } else {
            context.insert(CachedRecipeMetadataRecord(key: key, updatedAt: updatedAt, payload: payload))
        }
        try context.save()
    }

    private func saveRecord<Value: Encodable>(
        _ type: CachedExportsSnapshotRecord.Type,
        key: String,
        updatedAt: Date,
        value: Value
    ) throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedExportsSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        let payload = try encoder.encode(value)
        if let existing = try context.fetch(descriptor).first {
            existing.updatedAt = updatedAt
            existing.savedAt = .now
            existing.payload = payload
        } else {
            context.insert(CachedExportsSnapshotRecord(key: key, updatedAt: updatedAt, payload: payload))
        }
        try context.save()
    }
}
