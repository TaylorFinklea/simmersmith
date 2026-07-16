// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let normalCheckoutBallast = packageDirectory
    .appending(path: "../../ballast")
    .standardizedFileURL
let ballastPath = FileManager.default.fileExists(
    atPath: normalCheckoutBallast.appending(path: "Package.swift").path
) ? "../../ballast" : "../../../ballast"

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
        .executable(
            name: "SimmerSmithBallastEval",
            targets: ["SimmerSmithBallastEval"]
        ),
    ],
    dependencies: [
        .package(path: "../SimmerSmithKit"),
        .package(path: ballastPath),
    ],
    targets: [
        .target(
            name: "SimmerSmithBallastAdapter",
            dependencies: [
                "SimmerSmithKit",
                .product(name: "BallastCore", package: "Ballast"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SimmerSmithBallastEval",
            dependencies: [
                "SimmerSmithBallastAdapter",
                .product(name: "BallastCore", package: "Ballast"),
                .product(name: "BallastMock", package: "Ballast"),
            ]
        ),
        .testTarget(
            name: "SimmerSmithBallastAdapterTests",
            dependencies: [
                "SimmerSmithBallastAdapter",
                .product(name: "BallastCore", package: "Ballast"),
                .product(name: "BallastMock", package: "Ballast"),
            ]
        ),
    ]
)
