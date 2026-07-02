// swift-tools-version: 6.0
import PackageDescription

// SP-A foundation modules, pre-built ahead of CloudKit container provisioning
// (see .docs/ai/phases/cloudkit-sp-a-spec.md). Pure-Swift, CloudKit-free so they
// unit-test headlessly; the thin CKSyncEngine/CKRecord adapters land at the
// relevant build phases. NOT yet wired into the app target.
let package = Package(
    name: "SimmerSmithCloudKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GroceryMerge", targets: ["GroceryMerge"]),
        .library(name: "AIProviderKit", targets: ["AIProviderKit"]),
        .library(name: "CloudKitProvisioning", targets: ["CloudKitProvisioning"]),

        .library(name: "HouseholdSync", targets: ["HouseholdSync"]),
        .library(name: "HouseholdRecords", targets: ["HouseholdRecords"]),
    ],
    targets: [
        .target(name: "GroceryMerge"),
        .target(name: "AIProviderKit"),
        .target(name: "CloudKitProvisioning"),

        // Phase 2 household-zone CKSyncEngine driver. Swift 5 mode: CKSyncEngine's
        // delegate + CKRecord value types predate strict-concurrency annotation.
        // Depends on GroceryMerge for the Phase-4 field-merge resolver + codec, and on
        // HouseholdRecords + CloudKitProvisioning for the Phase-7 plain-CRUD migration path.
        .target(name: "HouseholdSync", dependencies: ["GroceryMerge", "HouseholdRecords", "CloudKitProvisioning"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Phase 2b typed household-record manifest + CKRecord codec + CKDSL generator.
        // Swift 5 mode for the CloudKit-guarded codec. Depends on CloudKitProvisioning for
        // RecordNames (the Phase-7 migration transform's det-key policy).
        .target(name: "HouseholdRecords", dependencies: ["CloudKitProvisioning"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GroceryMergeTests", dependencies: ["GroceryMerge"]),
        .testTarget(name: "AIProviderKitTests", dependencies: ["AIProviderKit"]),
        .testTarget(name: "CloudKitProvisioningTests", dependencies: ["CloudKitProvisioning"]),
        .testTarget(name: "HouseholdRecordsTests", dependencies: ["HouseholdRecords"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HouseholdSyncTests", dependencies: ["HouseholdSync", "GroceryMerge"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
