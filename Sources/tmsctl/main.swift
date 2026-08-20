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

// Commands that drive the Teams UI cannot safely run while the production app is doing
// the same thing: `TeamsUI.exclusive` serialises callers inside one process, not across
// processes, so two of them interleave halfway through a flyout and both fail. That is not
// a hypothetical — it manufactured a four-minute "profile button did not respond"
// stall during acceptance and contaminated the result.
//
// Read-only inspection (`health`, `audio`, `version`) is unaffected and stays available.
let uiDrivingCommands: Set<String> = [
    "get", "set", "clear", "selftest", "gate", "enable", "recover-window", "restart-teams",
]
if uiDrivingCommands.contains(command), !CommandLine.arguments.contains("--allow-contention") {
    let running = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.zanderdent.TeamsMusicStatus"
    }
    if running {
        FileHandle.standardError.write(Data("""
        refusing to run '\(command)': Teams Music Status is running and drives the same
        Teams UI. Two processes interleaving AX operations produce failures that belong to
        neither of them.

        Quit the app first (osascript -e 'quit app id "com.zanderdent.TeamsMusicStatus"'),
        or pass --allow-contention if you are deliberately testing contention.

        """.utf8))
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

case "recover-window":
    // The zero-window escalation, exercised deterministically. Prints the frontmost app
    // before and after so focus restoration is verifiable rather than asserted.
    requirePermission()
    printHeader("Window recovery by activation")
    let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
    print("health before: \(accessibility.health())")
    print("frontmost before: \(before)")
    let recovered = accessibility.activateToRestoreWindow()
    Thread.sleep(forTimeInterval: 1.5)
    let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
    print("recovered: \(recovered)")
    print("health after: \(accessibility.health())")
    print("frontmost after: \(after)")
    print(before == after
          ? "FOCUS RESTORED"
          : "FOCUS NOT RESTORED (was \(before), now \(after))")
    exit(recovered && before == after ? 0 : 1)

case "restart-teams":
    // The treeUnavailable escalation's actuator, on demand. Honours the same call-safety
    // rule as the automatic path: it refuses while audio is being captured.
    requirePermission()
    printHeader("Controlled Teams restart")
    if TeamsRestartRecovery.isAudioCaptureActive {
        print("REFUSED: audio capture is active — a call may be in progress")
        exit(2)
    }
    let outcome = await TeamsRestartRecovery.restartTeams()
    print("outcome: \(outcome)")
    let ok = outcome.isRelaunched
    if ok {
        target.handleTeamsRestart()
        do {
            try accessibility.ensureHealthy()
            print("health after: \(accessibility.health())")
        } catch {
            print("health after: FAILED — \(error.localizedDescription)")
            exit(1)
        }
    }
    exit(ok ? 0 : 1)

case "audio":
    print("audioCaptureActive: \(TeamsRestartRecovery.isAudioCaptureActive)")

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

    // For the local source, print the explicit reading rather than flattening it. "no
    // active playback" hid the difference between Spotify being stopped, not running, and
    // an Apple Event that failed -- the exact conflation this source was fixed to remove.
    if useLocal {
        let localSem = DispatchSemaphore(value: 0)
        var reading: Result<LocalPlaybackReading, Error>?
        Task {
            do { reading = .success(try await SpotifyLocalSource().read()) }
            catch { reading = .failure(error) }
            localSem.signal()
        }
        // Pump the main run loop instead of blocking it.
        //
        // A blocked main thread appears to starve Apple Event reply delivery: with
        // `semaphore.wait()` here, roughly one cold run in six never returned and hit the
        // full deadline, while the identical script on a free main thread completed 20/20
        // in ~200ms. A GUI app always has a live main run loop, so this is a property of
        // command-line callers rather than of the source.
        let deadline = Date().addingTimeInterval(20)
        var waited: DispatchTimeoutResult = .success
        while reading == nil {
            if Date() >= deadline { waited = .timedOut; break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if waited == .timedOut {
            print("✗ timed out after 20s reading the local Spotify app"); exit(1)
        }
        switch reading {
        case .success(let r)?:
            switch r {
            case .notRunning: print("state:   Spotify is not running")
            case .stopped:    print("state:   stopped")
            case .paused(let t), .playing(let t):
                print("state:   \(t.isPlaying ? "playing" : "paused")")
                print("track:   \(t.trackName)")
                print("artists: \(t.joinedArtists)")
                print("album:   \(t.albumName ?? "-")")
                print("render:  \"\(StatusTemplate().render(t))\"")
            }
        case .failure(let error)?:
            print("✗ \(error.localizedDescription)"); exit(1)
        case nil:
            print("✗ the source returned without a result — please report this"); exit(1)
        }
        exit(0)
    }
    let semaphore = DispatchSemaphore(value: 0)
    // No default "success with no playback".
    //
    // This started as `.success(nil)`, with the wait result discarded. Any read that had
    // not finished in time therefore printed "no active playback" -- a reading this tool
    // invented rather than observed, indistinguishable from Spotify genuinely being idle.
    // It made the Local source look unreliable in exactly the diagnostic used to judge it.
    var result: Result<TrackPresence?, Error>?
    Task {
        do { result = .success(try await source.fetch()) }
        catch { result = .failure(error) }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 40) == .timedOut {
        print("✗ timed out after 40s waiting for \(source.displayName)")
        exit(1)
    }
    guard let result else {
        print("✗ the source returned without a result — please report this")
        exit(1)
    }
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
