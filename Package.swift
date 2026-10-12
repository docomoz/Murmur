// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-update for the DMG build (build.sh embeds the framework; the App Store build compiles it out).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Murmur",
            linkerSettings: [
                // Sparkle.framework lives in Contents/Frameworks of the hand-assembled bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
