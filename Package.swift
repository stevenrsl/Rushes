// swift-tools-version: 6.0
import PackageDescription

// A plain SwiftPM executable, like Cairn and Journal's Mac app: `build.sh` wraps
// the binary in the .app bundle Finder and the Dock expect, and there is no
// Xcode project to keep in sync.
let package = Package(
    name: "Rushes",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Rushes",
            path: "Sources/Rushes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RushesTests",
            dependencies: ["Rushes"],
            path: "Tests/RushesTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
