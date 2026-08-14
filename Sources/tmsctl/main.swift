import AppKit
import Foundation
import TeamsMusicStatusCore

// tmsctl — diagnostics and acceptance harness.
//
// Drives the *production* Core code from a terminal so the Teams automation can be
// exercised and verified without the GUI. This is the tool the acceptance runs use.
//
//   tmsctl health              report Teams accessibility health
//   tmsctl enable              run the accessibility enabler, report before/after
//   tmsctl selftest            validate every Teams selector
//   tmsctl get                 read the current Teams status message
//   tmsctl set "<text>"        write a status message and verify it
//   tmsctl clear               delete the status message
//   tmsctl gate                run the full Hard Gate 0 acceptance matrix
//   tmsctl spotify             read the currently-playing track from the chosen source
//   tmsctl version             installed Teams version

// Long acceptance runs are watched from a file; block buffering would hide all
// progress until exit.
setvbuf(stdout, nil, _IOLBF, 0)

func frontmostAppName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
}

func printHeader(_ title: String) {
    print("\n\u{1B}[1m\(title)\u{1B}[0m")
    print(String(repeating: "─", count: max(8, title.count)))
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "health"

let accessibility = TeamsAccessibility()
let target = TeamsAXTarget(accessibility: accessibility)

func requirePermission() {
    guard TeamsAccessibility.hasAccessibilityPermission else {
        print("✗ Accessibility permission is not granted to this process.")
        print("  Grant it to your terminal (or the app running it) in")
        print("  System Settings ▸ Privacy & Security ▸ Accessibility, then retry.")
        exit(3)
    }
}

switch command {

case "version":
    print("Installed Teams: \(TeamsProcesses.installedVersion() ?? "not installed")")
    print("Teams running:   \(TeamsProcesses.isRunning)")
    print("WebView helpers: \(TeamsProcesses.webViewHelperPIDs().count)")

case "health":
    requirePermission()
    print("health: \(accessibility.health())")
    print("availability: \(target.availability())")

case "enable":
    requirePermission()
    printHeader("Accessibility enabler")
    print("before: \(accessibility.health())")
    let started = Date()
    do {
        try accessibility.ensureHealthy()
        print("after:  \(accessibility.health())  (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
    } catch {
        print("FAILED: \(error.localizedDescription)")
        exit(1)
    }

case "selftest":
    requirePermission()
    printHeader("Selector self-test")
    do {
        let report = try TeamsSelfTest(accessibility: accessibility).run()
        print(report.summary)
        exit(report.passed ? 0 : 1)
    } catch {
        print("FAILED: \(error.localizedDescription)")
        exit(1)
    }

case "get":
    requirePermission()
    do {
        let status = try target.readCurrentStatus()
        print("status: \(status.map { "\"\($0)\"" } ?? "<none>")")
    } catch {
        print("FAILED: \(error.localizedDescription)")
        exit(1)
    }

case "set":
    requirePermission()
    guard arguments.count > 1 else { print("usage: tmsctl set \"<text>\""); exit(2) }
    let before = frontmostAppName()
    do {
        try target.apply(status: arguments[1])
        let after = frontmostAppName()
        print("✓ status applied and verified")
        for warning in target.lastWarnings { print("  ⚠︎ \(warning)") }
        print("frontmost \(before) → \(after): \(before == after ? "PRESERVED ✓" : "STOLEN ✗")")
        exit(before == after ? 0 : 4)
    } catch {
        print("✗ \(error.localizedDescription)")
        exit(1)
    }

case "clear":
    requirePermission()
    do { try target.clearStatus(); print("✓ cleared") }
    catch { print("✗ \(error.localizedDescription)"); exit(1) }

case "spotify-config":
    // Where the client ID is (or isn't) coming from, without printing it.
    let clientID = AppConfiguration.spotifyClientID
    print("client ID: \(clientID.map { "found (\($0.count) chars)" } ?? "NOT CONFIGURED")")
    print("redirect:  \(AppConfiguration.spotifyRedirectURI.absoluteString)")
    print("bundle:    \(Bundle.main.bundleIdentifier ?? "<none>")")
    if let problem = clientID == nil ? AppConfiguration.missingClientIDMessage : nil {
        print("\n\(problem)")
    }

case "connect":
    // Same PKCE flow the app uses, run where its errors are visible.
    guard let clientID = AppConfiguration.spotifyClientID else {
        print("✗ \(AppConfiguration.missingClientIDMessage)")
        exit(2)
    }
    let auth = SpotifyAuth(configuration: .init(clientID: clientID,
                                                redirectURI: AppConfiguration.spotifyRedirectURI))
    print("opening the Spotify consent page…")
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    Task {
        do { try await auth.authorize() } catch { failure = error }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 200)
    if let failure {
        print("✗ \(failure.localizedDescription)")
        exit(1)
    }
    print("✓ connected; tokens stored in the Keychain")

case "spotify":
    let useLocal = arguments.contains("--local")
    let source: PresenceSource
    if useLocal {
        source = SpotifyLocalSource()
    } else {
        guard let clientID = AppConfiguration.spotifyClientID else {
            print("✗ no client ID configured"); exit(2)
        }
        source = SpotifyWebAPISource(
            auth: SpotifyAuth(configuration: .init(clientID: clientID,
                                                   redirectURI: AppConfiguration.spotifyRedirectURI)))
    }
    printHeader("Spotify — \(source.displayName)")
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<TrackPresence?, Error> = .success(nil)
    Task {
        do { result = .success(try await source.fetch()) }
        catch { result = .failure(error) }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 40)
    switch result {
    case .success(let presence):
        if let presence {
            print("track:   \(presence.trackName)")
            print("artists: \(presence.joinedArtists)")
            print("album:   \(presence.albumName ?? "-")")
            print("playing: \(presence.isPlaying)")
            print("render:  \"\(StatusTemplate().render(presence))\"")
        } else {
            print("no active playback")
        }
    case .failure(let error):
        print("✗ \(error.localizedDescription)")
        exit(1)
    }

case "gate":
    requirePermission()
    GateRunner(accessibility: accessibility, target: target).run(arguments: arguments)

default:
    print("""
    tmsctl — Teams Music Status diagnostics

      health      Teams accessibility health
      enable      run the accessibility enabler
      selftest    validate all Teams selectors
      get         read the current Teams status
      set "<t>"   write and verify a status
      clear       delete the status message
      gate        run the Hard Gate 0 acceptance matrix
      version     installed Teams version
    """)
}
