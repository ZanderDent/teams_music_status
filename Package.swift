// swift-tools-version: 6.0
import PackageDescription

// Layout note: SwiftPM requires non-overlapping target roots, so the conceptual
// grouping from the project plan lives as subdirectories inside two targets:
//
//   Sources/TeamsMusicStatusCore/   Core, Models, Presence (sources), Targets, Services, Utilities
//   Sources/TeamsMusicStatusApp/    App, UI
//
// Everything testable lives in the Core library; the executable is only the shell.
let package = Package(
    name: "TeamsMusicStatus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TeamsMusicStatus", targets: ["TeamsMusicStatusApp"]),
        // Diagnostics + acceptance harness. Drives the real Core code from a terminal so
        // the Teams automation can be exercised and verified without the GUI.
        .executable(name: "tmsctl", targets: ["tmsctl"]),
        .library(name: "TeamsMusicStatusCore", targets: ["TeamsMusicStatusCore"]),
    ],
    targets: [
        .target(
            name: "TeamsMusicStatusCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TeamsMusicStatusApp",
            dependencies: ["TeamsMusicStatusCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "tmsctl",
            dependencies: ["TeamsMusicStatusCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TeamsMusicStatusCoreTests",
            dependencies: ["TeamsMusicStatusCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
