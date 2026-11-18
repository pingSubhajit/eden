// swift-tools-version: 6.0
import PackageDescription

// What Eden for the Mac and Eden for iPhone and iPad share: where things are
// kept, the address field's understanding of what was typed, history and
// its suggestions, the blocker's rules, and the data that syncs. No AppKit
// and no UIKit: each app draws its own.
let package = Package(
    name: "EdenCore",
    platforms: [.macOS(.v14), .iOS("27.0")],
    products: [
        .library(name: "EdenCore", targets: ["EdenCore"]),
    ],
    targets: [
        .target(
            name: "EdenCore",
            path: "Sources/EdenCore",
            // The Mac app's own language mode, which this code was written
            // in and is still compiled with there.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdenCoreTests",
            dependencies: ["EdenCore"],
            path: "Tests/EdenCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
