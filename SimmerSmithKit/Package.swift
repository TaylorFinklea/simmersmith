// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimmerSmithKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "SimmerSmithKit", targets: ["SimmerSmithKit"]),
    ],
    dependencies: [
        .package(path: "../SimmerSmithCloudKit"),
    ],
    targets: [
        .target(
            name: "SimmerSmithKit",
            dependencies: [
                .product(name: "HouseholdRecords", package: "SimmerSmithCloudKit"),
            ]
        ),
        .testTarget(
            name: "SimmerSmithKitTests",
            dependencies: ["SimmerSmithKit"]
        ),
    ]
)
