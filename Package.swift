// swift-tools-version: 6.0
import PackageDescription

// Layout note: SwiftPM requires non-overlapping target roots, so the conceptual
// grouping from the project plan lives as subdirectories inside two targets:
//
//   Sources/TeamsMusicStatusCore/   Core, Models, Presence (sources), Targets, Services, Utilities
//   Sources/TeamsMusicStatusApp/    App, UI
//
// Everything testable lives in the Core library; the executable is only the shell.
//
// ## Windows
//
// The Windows build compiles a *subset* of the same Core directory rather than a copy of
// it: the files listed in `portableCoreSources` import nothing but Foundation and are
// byte-identical between platforms. Everything else in Core is macOS-specific (AppKit,
// ApplicationServices, Security, ServiceManagement, Combine) and is replaced by a Windows
// implementation rather than ported.
//
// Listing sources explicitly — rather than excluding — is deliberate: a new macOS-only
// file added to Core cannot silently break the Windows build, and a file intended to be
// shared has to be named here, which is a decision someone makes on purpose.

let portableCoreSources = [
    "Core/AccessibleElement.swift",
    "Core/AppState.swift",
    "Core/OnboardingPolicy.swift",
    "Core/PresenceSource.swift",
    "Core/PresenceTarget.swift",
    "Core/SyncEngine.swift",
    "Models/StatusTemplate.swift",
    "Models/TrackPresence.swift",
    "Services/Logging/WindowsLog.swift",
    "Services/RestoreStateStore.swift",
    "Targets/Teams/TeamsSelectors.swift",
    "Targets/Teams/TeamsUI.swift",
    "Utilities/ProfanityFilter.swift",
    "Utilities/UnicodeSanitizer.swift",
]

// macOS-only files. Listed so SwiftPM does not warn about unhandled sources, and so the
// split between shared and platform-specific code is visible in one place. Kept alongside
// the explicit `sources` allow-list above rather than replacing it: an allow-list means a
// new macOS-only file cannot silently break the Windows build, and the exclusions document
// what was deliberately left behind.
let macOSOnlyCoreSources = [
    "Core/AppEnvironment.swift",
    "Core/PresenceCoordinator.swift",
    "Presence",
    "Services/AppSettings.swift",
    "Services/Keychain",
    "Services/Logging/Log.swift",
    "Services/LoginItem",
    "Targets/Teams/AXElement.swift",
    "Targets/Teams/TeamsAXTarget.swift",
    "Targets/Teams/TeamsAccessibility.swift",
    "Targets/Teams/TeamsProcesses.swift",
    "Targets/Teams/TeamsSelfTest.swift",
]

let macOSOnlyTestSources = [
    "AutomationPermissionTests.swift",
    "OnboardingReachabilityTests.swift",
    "SignedOutTests.swift",
    "SpotifyLocalLiveTests.swift",
    "SpotifyLocalSourceTests.swift",
    "SpotifyTests.swift",
    "TeamsTargetTests.swift",
]

// Tests that exercise only the portable core. The rest drive AppKit, Apple Events or the
// macOS accessibility API and have Windows equivalents of their own.
let portableTestSources = [
    "ProfanityFilterTests.swift",
    "RestoreStateStoreTests.swift",
    "SyncEngineTests.swift",
    "TextRenderingTests.swift",
    "WriteDeferralTests.swift",
]

#if os(Windows)

let package = Package(
    name: "TeamsMusicStatus",
    products: [
        .library(name: "TeamsMusicStatusCore", targets: ["TeamsMusicStatusCore"]),
        .library(name: "TeamsMusicStatusWindows", targets: ["TeamsMusicStatusWindows"]),
        // The application: a notification-area icon, no window unless you ask for one.
        .executable(name: "TeamsMusicStatus", targets: ["TeamsMusicStatusWin"]),
        // Diagnostics harness, mirroring `tmsctl` on macOS: drives the real product code
        // from a terminal so each layer can be verified without a GUI.
        .executable(name: "tmswinctl", targets: ["tmswinctl"]),
    ],
    targets: [
        .target(
            name: "TeamsMusicStatusCore",
            exclude: macOSOnlyCoreSources,
            sources: portableCoreSources,
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Flat C ABI over UI Automation, MSAA and the WinRT media session. Swift can call
        // C directly, but reaching COM and WinRT from Swift means hand-rolling vtable
        // dispatch; wrapping them in C++ keeps that in one auditable place.
        .target(
            name: "CTeamsWin",
            linkerSettings: [
                .linkedLibrary("windowsapp"),   // WinRT activation (media session)
                .linkedLibrary("oleacc"),       // MSAA — the activation path that does not steal focus
                .linkedLibrary("uiautomationcore"),
                .linkedLibrary("ole32"),
                .linkedLibrary("oleaut32"),
                .linkedLibrary("user32"),
                .linkedLibrary("version"),   // GetFileVersionInfo, for the Teams build number
                .linkedLibrary("shell32"),   // tray icon, ShellExecute
                .linkedLibrary("gdi32"),     // the tray icon is drawn at run time
                .linkedLibrary("comctl32"),
            ]
        ),
        .target(
            name: "TeamsMusicStatusWindows",
            dependencies: ["TeamsMusicStatusCore", "CTeamsWin"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The product: a notification-area application, no window unless you ask for one.
        //
        // /SUBSYSTEM:WINDOWS stops a console flashing up at launch; /ENTRY:mainCRTStartup
        // is required with it, because Swift emits a C `main` rather than `WinMain`.
        .executableTarget(
            name: "TeamsMusicStatusWin",
            dependencies: ["TeamsMusicStatusCore", "TeamsMusicStatusWindows", "CTeamsWin"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS",
                                           "-Xlinker", "/ENTRY:mainCRTStartup"])]
        ),
        .executableTarget(
            name: "tmswinctl",
            dependencies: ["TeamsMusicStatusCore", "TeamsMusicStatusWindows"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TeamsMusicStatusCoreTests",
            dependencies: ["TeamsMusicStatusCore"],
            exclude: macOSOnlyTestSources,
            sources: portableTestSources,
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    // C++20, not 17: C++/WinRT under clang needs the standard <coroutine> header. With
    // C++17 winrt/base.h falls back to <experimental/coroutine>, which MSVC ships but
    // explicitly refuses to compile under clang.
    cxxLanguageStandard: .cxx20
)

#else

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

#endif
