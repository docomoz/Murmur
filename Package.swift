// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-update for the DMG build (build.sh embeds the framework; the App Store build compiles it out).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        // Anonymous usage statistics (Sources/Murmur/Analytics.swift is the only file that imports it).
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", exact: "2.14.2"),
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ],
            path: "Sources/Murmur",
            linkerSettings: [
                // Sparkle.framework lives in Contents/Frameworks of the hand-assembled bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
