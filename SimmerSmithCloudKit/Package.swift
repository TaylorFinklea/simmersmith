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
        .library(name: "CoexistenceSpike", targets: ["CoexistenceSpike"]),
        .library(name: "HouseholdSync", targets: ["HouseholdSync"]),
    ],
    targets: [
        .target(name: "GroceryMerge"),
        .target(name: "AIProviderKit"),
        .target(name: "CloudKitProvisioning"),
        // Phase 0.5 spike — runs on device; Swift 5 mode to keep Core Data /
        // CloudKit value types out of strict-concurrency churn for a throwaway.
        .target(name: "CoexistenceSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Phase 2 household-zone CKSyncEngine driver. Swift 5 mode: CKSyncEngine's
        // delegate + CKRecord value types predate strict-concurrency annotation.
        .target(name: "HouseholdSync", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GroceryMergeTests", dependencies: ["GroceryMerge"]),
        .testTarget(name: "AIProviderKitTests", dependencies: ["AIProviderKit"]),
        .testTarget(name: "CloudKitProvisioningTests", dependencies: ["CloudKitProvisioning"]),
    ]
)
