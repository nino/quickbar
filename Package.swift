// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quickbar",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: matching, ranking, learning, calculator, config. No AppKit.
        .target(
            name: "QuickbarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The AppKit app.
        .executableTarget(
            name: "Quickbar",
            dependencies: ["QuickbarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuickbarCoreTests",
            dependencies: ["QuickbarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
