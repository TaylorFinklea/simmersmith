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
    targets: [
        .target(name: "SimmerSmithKit"),
        .testTarget(
            name: "SimmerSmithKitTests",
            dependencies: ["SimmerSmithKit"]
        ),
    ]
)
