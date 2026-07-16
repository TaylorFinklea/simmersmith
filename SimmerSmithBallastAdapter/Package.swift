// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimmerSmithBallastAdapter",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SimmerSmithBallastAdapter",
            targets: ["SimmerSmithBallastAdapter"]
        ),
    ],
    dependencies: [
        .package(path: "../SimmerSmithKit"),
        .package(path: "../../../ballast"),
    ],
    targets: [
        .target(
            name: "SimmerSmithBallastAdapter",
            dependencies: [
                "SimmerSmithKit",
                .product(name: "BallastCore", package: "Ballast"),
            ]
        ),
        .testTarget(
            name: "SimmerSmithBallastAdapterTests",
            dependencies: ["SimmerSmithBallastAdapter"]
        ),
    ]
)
