import AppKit
import Foundation
import TeamsRichPresenceCore

// trpctl — diagnostics and acceptance harness.
//
// Drives the *production* Core code from a terminal so the Teams automation can be
// exercised and verified without the GUI. This is the tool the acceptance runs use.
//
//   trpctl health              report Teams accessibility health
//   trpctl enable              run the accessibility enabler, report before/after
//   trpctl selftest            validate every Teams selector
//   trpctl get                 read the current Teams status message
//   trpctl set "<text>"        write a status message and verify it
//   trpctl clear               delete the status message
//   trpctl gate                run the full Hard Gate 0 acceptance matrix
//   trpctl spotify             read the currently-playing track from the chosen source
//   trpctl version             installed Teams version

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
    guard arguments.count > 1 else { print("usage: trpctl set \"<text>\""); exit(2) }
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

case "gate":
    requirePermission()
    GateRunner(accessibility: accessibility, target: target).run(arguments: arguments)

default:
    print("""
    trpctl — Teams Rich Presence diagnostics

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
