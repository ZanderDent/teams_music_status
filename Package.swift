// swift-tools-version: 6.0
import PackageDescription

// Layout note: SwiftPM requires non-overlapping target roots, so the conceptual
// grouping from the project plan lives as subdirectories inside two targets:
//
//   Sources/TeamsRichPresenceCore/   Core, Models, Presence (sources), Targets, Services, Utilities
//   Sources/TeamsRichPresenceApp/    App, UI
//
// Everything testable lives in the Core library; the executable is only the shell.
let package = Package(
    name: "TeamsRichPresence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TeamsRichPresence", targets: ["TeamsRichPresenceApp"]),
        // Diagnostics + acceptance harness. Drives the real Core code from a terminal so
        // the Teams automation can be exercised and verified without the GUI.
        .executable(name: "trpctl", targets: ["trpctl"]),
        .library(name: "TeamsRichPresenceCore", targets: ["TeamsRichPresenceCore"]),
    ],
    targets: [
        .target(
            name: "TeamsRichPresenceCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TeamsRichPresenceApp",
            dependencies: ["TeamsRichPresenceCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "trpctl",
            dependencies: ["TeamsRichPresenceCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TeamsRichPresenceCoreTests",
            dependencies: ["TeamsRichPresenceCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
