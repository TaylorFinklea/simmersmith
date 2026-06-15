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
    ],
    targets: [
        .target(name: "GroceryMerge"),
        .target(name: "AIProviderKit"),
        .testTarget(name: "GroceryMergeTests", dependencies: ["GroceryMerge"]),
        .testTarget(name: "AIProviderKitTests", dependencies: ["AIProviderKit"]),
    ]
)
