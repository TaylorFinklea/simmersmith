import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
#endif

/// SP-C slice 5 — pantry state delegated to PantryRepository (household zone).
///
/// `AppState.pantryItems` is an @Observable stored property that views bind to.
/// Each method delegates to `pantryRepository` when the CloudKit session is ready,
/// then mirrors the repo's in-memory list onto `pantryItems` so views update.
///
/// The `addPantryItem(_ body:)` overload accepting a Fly `PantryItemAddBody` is
/// preserved for call sites (SaveLeftoversToFreezerSheet, PantryItemEditorSheet)
/// that pre-date the CloudKit repo. It maps the body to the repo's parameters.
extension AppState {

    // MARK: - Read

    func loadPantryItems() async {
        #if canImport(CloudKit)
        guard let repo = pantryRepository else { return }
        repo.loadPantryItems()
        pantryItems = repo.pantryItems
        #endif
    }

    // MARK: - Add

    /// Add a pantry item via the repo.
    func addPantryItem(_ body: SimmerSmithAPIClient.PantryItemAddBody) async {
        #if canImport(CloudKit)
        guard let repo = pantryRepository else { return }
        repo.addPantryItem(
            stapleName: body.stapleName,
            normalizedName: body.normalizedName,
            notes: body.notes,
            isActive: body.isActive,
            typicalQuantity: body.typicalQuantity,
            typicalUnit: body.typicalUnit,
            recurringQuantity: body.recurringQuantity,
            recurringUnit: body.recurringUnit,
            recurringCadence: body.recurringCadence,
            category: body.category,
            categories: body.categories,
            frozenAt: body.frozenAt
        )
        pantryItems = repo.pantryItems
        #endif
    }

    // MARK: - Quick-add

    /// Quick-add an ingredient to the pantry from a grocery or plan-shopping row.
    /// Dedupes by normalizedName — returns `true` when a new row was created.
    @discardableResult
    func quickAddIngredientToPantry(
        name: String,
        category: String = "",
        unit: String = "",
        normalizedNameHint: String = ""
    ) async -> Bool {
        #if canImport(CloudKit)
        guard let repo = pantryRepository else { return false }
        let added = repo.quickAddIngredientToPantry(
            name: name,
            category: category,
            unit: unit,
            normalizedNameHint: normalizedNameHint
        )
        pantryItems = repo.pantryItems
        return added
        #else
        return false
        #endif
    }

    // MARK: - Patch

    func patchPantryItem(itemID: String, body: SimmerSmithAPIClient.PantryItemPatchBody) async {
        #if canImport(CloudKit)
        guard let repo = pantryRepository else { return }
        repo.patchPantryItem(
            itemID: itemID,
            stapleName: body.stapleName,
            notes: body.notes,
            isActive: body.isActive,
            typicalQuantity: body.typicalQuantity.map { .set($0) } ?? (body.clearTypicalQuantity == true ? .clear : nil),
            typicalUnit: body.typicalUnit,
            recurringQuantity: body.recurringQuantity.map { .set($0) } ?? (body.clearRecurringQuantity == true ? .clear : nil),
            recurringUnit: body.recurringUnit,
            recurringCadence: body.recurringCadence,
            category: body.category,
            categories: body.categories,
            frozenAt: body.frozenAt.map { .set($0) } ?? (body.clearFrozenAt == true ? .clear : nil)
        )
        pantryItems = repo.pantryItems
        #endif
    }

    // MARK: - Delete (soft)

    func deletePantryItem(itemID: String) async {
        #if canImport(CloudKit)
        guard let repo = pantryRepository else { return }
        repo.deletePantryItem(itemID: itemID)
        pantryItems = repo.pantryItems
        #endif
    }

    // MARK: - Apply recurrings

    /// Fold recurring pantry items into the current week's grocery list.
    /// Delegates to PantryRepository.applyPantryToCurrentWeek.
    func applyPantryToCurrentWeek() async {
        #if canImport(CloudKit)
        guard let weekID = currentWeek?.weekId,
              let pantryRepo = pantryRepository,
              let groceryRepo = groceryRepository else { return }
        pantryRepo.applyPantryToCurrentWeek(weekID: weekID, groceryRepository: groceryRepo)
        pantryItems = pantryRepo.pantryItems
        #endif
    }
}
