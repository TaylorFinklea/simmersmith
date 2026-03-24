import Foundation
import SwiftData

public let simmersmithModelTypes: [any PersistentModel.Type] = [
    CachedProfileSnapshotRecord.self,
    CachedWeekSnapshotRecord.self,
    CachedRecipesSnapshotRecord.self,
    CachedRecipeMetadataRecord.self,
    CachedExportsSnapshotRecord.self,
    CachedGroceryCheckState.self,
]

public func makeSimmerSmithModelContainer(inMemory: Bool = false) throws -> ModelContainer {
    let schema = Schema(simmersmithModelTypes)
    let configuration = ModelConfiguration(
        "SimmerSmith",
        schema: schema,
        isStoredInMemoryOnly: inMemory,
        allowsSave: true,
        groupContainer: .none,
        cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
}
