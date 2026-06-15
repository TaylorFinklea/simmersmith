// swift-tools-version: 6.0
import PackageDescription

// THROWAWAY de-risking spike (see .docs/ai/phases/cloudkit-migration-spikes-spec.md).
// Delete after the report is written.
let package = Package(
    name: "GroceryMergeSim",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GroceryMergeSim"),
        .testTarget(
            name: "GroceryMergeSimTests",
            dependencies: ["GroceryMergeSim"]
        ),
    ]
)
