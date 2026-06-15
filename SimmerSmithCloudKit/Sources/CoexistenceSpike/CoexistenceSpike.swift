#if canImport(CloudKit) && canImport(CoreData)
import CloudKit
import CoreData
import Foundation

/// SP-A Phase 0.5 coexistence spike (SINGLE iCloud account).
///
/// Question (review finding E2 / spec §4.2): do `NSPersistentCloudKitContainer`
/// (a private-DB Core Data mirror, the spec's Phase 1 choice) and a manual CloudKit
/// stack using a custom zone + record + subscription — the primitives `CKSyncEngine`
/// is built on — coexist in ONE container without interfering? The answer picks
/// Phase 1's mechanism: NSPCKC (easy, free Core Data) if they coexist, else
/// CKSyncEngine-everywhere (uniform, uses the GroceryMerge resolver).
///
/// Run from an entitled, iCloud-signed-in target (e.g. a debug button calling
/// `await CoexistenceSpike().run()`); it returns a human-readable pass/fail. The
/// CKShare cross-account half of 0.5 is separate (needs a 2nd account, manual).
@MainActor
public struct CoexistenceSpike {
    public let containerID: String
    public init(containerID: String = "iCloud.app.simmersmith.cloud") { self.containerID = containerID }

    public func run() async -> String {
        var log: [String] = ["Phase 0.5 coexistence spike — container \(containerID)"]

        // 1) NSPersistentCloudKitContainer private mirror.
        do {
            let stack = NSPCKCStack(containerID: containerID)
            try await stack.load()
            try stack.writeNote(text: "coexistence \(UUID().uuidString.prefix(8))")
            log.append("✅ NSPCKC: store loaded + note written (count=\(try stack.count()))")
        } catch {
            log.append("❌ NSPCKC failed: \(error.localizedDescription)")
        }

        // 2) Manual CloudKit (custom zone + record + zone subscription) in the SAME container.
        do {
            let manual = ManualCloudKitStack(containerID: containerID)
            try await manual.ensureZone()
            let name = try await manual.writeAndReadBack()
            try await manual.ensureSubscription()
            log.append("✅ Manual CloudKit: zone + record round-trip ('\(name)') + subscription")
        } catch {
            log.append("❌ Manual CloudKit failed: \(error.localizedDescription)")
        }

        log.append("→ Both ✅ ⇒ NSPCKC + a CKSyncEngine-style stack coexist; Phase 1 can use NSPCKC.")
        log.append("→ Either ❌ (esp. a token/zone/notification clash) ⇒ go CKSyncEngine-everywhere.")
        return log.joined(separator: "\n")
    }
}

/// Private-DB Core Data mirror via a programmatic model (no .xcdatamodeld needed).
@MainActor
final class NSPCKCStack {
    let container: NSPersistentCloudKitContainer

    init(containerID: String) {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "SpikeNote"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let idAttr = NSAttributeDescription()
        idAttr.name = "id"; idAttr.attributeType = .stringAttributeType; idAttr.isOptional = true
        let textAttr = NSAttributeDescription()
        textAttr.name = "text"; textAttr.attributeType = .stringAttributeType; textAttr.isOptional = true
        entity.properties = [idAttr, textAttr]
        model.entities = [entity]

        container = NSPersistentCloudKitContainer(name: "CoexistenceSpike", managedObjectModel: model)
        if let desc = container.persistentStoreDescriptions.first {
            desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            desc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            desc.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        }
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
            }
        }
    }

    func writeNote(text: String) throws {
        let ctx = container.viewContext
        let note = NSEntityDescription.insertNewObject(forEntityName: "SpikeNote", into: ctx)
        note.setValue(UUID().uuidString, forKey: "id")
        note.setValue(text, forKey: "text")
        try ctx.save()
    }

    func count() throws -> Int {
        try container.viewContext.count(for: NSFetchRequest<NSManagedObject>(entityName: "SpikeNote"))
    }
}

/// Manual CloudKit primitives in the same container's private DB.
final class ManualCloudKitStack {
    let db: CKDatabase
    let zoneID: CKRecordZone.ID

    init(containerID: String) {
        db = CKContainer(identifier: containerID).privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: "coexistence-spike", ownerName: CKCurrentUserDefaultName)
    }

    func ensureZone() async throws {
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    }

    func writeAndReadBack() async throws -> String {
        // reuse the deployed HouseholdProfile type as a throwaway record in the spike zone
        let recordID = CKRecord.ID(recordName: "coexistence-\(UUID().uuidString)", zoneID: zoneID)
        let record = CKRecord(recordType: "HouseholdProfile", recordID: recordID)
        record["name"] = "manual stack"
        _ = try await db.modifyRecords(saving: [record], deleting: [])
        let read = try await db.record(for: recordID)
        return read["name"] as? String ?? ""
    }

    func ensureSubscription() async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "coexistence-zone-sub")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await db.modifySubscriptions(saving: [subscription], deleting: [])
    }
}
#endif
