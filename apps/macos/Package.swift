// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Eden",
    platforms: [.macOS(.v14)],
    dependencies: [
        // What the Mac app shares with Eden for iPhone and iPad.
        .package(path: "../../packages/EdenCore"),
    ],
    targets: [
        .executableTarget(
            name: "Eden",
            dependencies: [.product(name: "EdenCore", package: "EdenCore")],
            path: "Sources/Eden",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdenTests",
            dependencies: ["Eden", .product(name: "EdenCore", package: "EdenCore")],
            path: "Tests/EdenTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
