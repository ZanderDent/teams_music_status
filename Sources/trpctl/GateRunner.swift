import AppKit
import Foundation
import TeamsRichPresenceCore

/// Hard Gate 0 acceptance matrix.
///
/// Proves, against the real installed Teams, that status automation is deterministic in
/// every window state the product must survive — and that the user's frontmost
/// application is never disturbed.
///
/// Run with `trpctl gate`. Add `--with-restart` to include the (disruptive) Teams
/// quit/relaunch case.
struct GateRunner {
    let accessibility: TeamsAccessibility
    let target: TeamsAXTarget

    struct Outcome {
        let name: String
        let passed: Bool
        let detail: String
        let focusPreserved: Bool?
    }

    private func frontmost() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    }

    /// Run one case: apply a status, verify the read-back, and check focus was preserved.
    private func statusCase(_ name: String, text: String) -> Outcome {
        let before = frontmost()
        do {
            try target.apply(status: text)
            let readBack = try target.readCurrentStatus()
            let after = frontmost()
            let matched = readBack == text
            var detail = matched ? "read back \"\(readBack ?? "")\"" : "MISMATCH: read \"\(readBack ?? "<nil>")\""
            if !target.lastWarnings.isEmpty {
                detail += " | warnings: \(target.lastWarnings.joined(separator: "; "))"
            }
            return Outcome(name: name, passed: matched, detail: detail,
                           focusPreserved: before == after)
        } catch {
            return Outcome(name: name, passed: false,
                           detail: error.localizedDescription,
                           focusPreserved: before == frontmost())
        }
    }

    /// Move focus somewhere that is definitely not Teams, so "focus preserved" means something.
    private func parkFocusAwayFromTeams() {
        let candidates = ["com.microsoft.VSCode", "com.apple.finder"]
        for identifier in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                app.activate()
                _ = AXPoll.wait(timeout: 3) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == identifier }
                return
            }
        }
    }

    func run(arguments: [String]) {
        let includeRestart = arguments.contains("--with-restart")
        var outcomes: [Outcome] = []

        print("\n\u{1B}[1mHard Gate 0 — Teams automation acceptance\u{1B}[0m")
        print("Teams version: \(TeamsProcesses.installedVersion() ?? "unknown")\n")

        // Record the user's real status so it can be put back at the end.
        parkFocusAwayFromTeams()
        let originalStatus = try? target.readCurrentStatus()
        print("original status: \(originalStatus.map { "\"\($0)\"" } ?? "<none>")\n")

        // 0. Selector self-test — everything below is meaningless if the UI moved.
        do {
            let report = try TeamsSelfTest(accessibility: accessibility).run()
            outcomes.append(Outcome(name: "selector self-test", passed: report.passed,
                                    detail: report.passed
                                        ? "\(report.entries.count) selectors checked"
                                        : "missing: \(report.failures.map(\.selector).joined(separator: ", "))",
                                    focusPreserved: nil))
            if !report.passed { print(report.summary) }
        } catch {
            outcomes.append(Outcome(name: "selector self-test", passed: false,
                                    detail: error.localizedDescription, focusPreserved: nil))
        }

        // 1. Teams open and backgrounded — the primary case.
        parkFocusAwayFromTeams()
        outcomes.append(statusCase("1. backgrounded", text: "♪ Gate 1 backgrounded"))

        // 2. Track-change style consecutive writes.
        outcomes.append(statusCase("2. consecutive update", text: "♪ Gate 2 second write"))

        // 3. Minimized.
        if let pid = TeamsProcesses.pid() {
            let app = AXElement(pid: pid)
            if let windows = app.rawAttribute(kAXWindowsAttribute as String) as? [AXUIElement] {
                for window in windows {
                    AXElement(window).setAttribute(kAXMinimizedAttribute as String, kCFBooleanTrue)
                }
            }
            _ = AXPoll.wait(timeout: 5) { accessibility.health() == .minimized }
            print("   (Teams minimized: health=\(accessibility.health()))")
        }
        parkFocusAwayFromTeams()
        outcomes.append(statusCase("3. minimized → recovered", text: "♪ Gate 3 minimized"))

        // 4. No open main window.
        if let pid = TeamsProcesses.pid() {
            let app = AXElement(pid: pid)
            if let close = app.firstDescendant(where: { $0.subrole == "AXCloseButton" }) {
                close.performAction()
            }
            _ = AXPoll.wait(timeout: 6) { accessibility.health() == .noWindow }
            print("   (Teams window closed: health=\(accessibility.health()))")
        }
        parkFocusAwayFromTeams()
        outcomes.append(statusCase("4. no window → recovered", text: "♪ Gate 4 no window"))

        // 5. Full Teams restart.
        if includeRestart {
            print("\n   restarting Teams…")
            if let app = TeamsProcesses.runningApp() {
                app.terminate()
                _ = AXPoll.wait(timeout: 40) { !TeamsProcesses.isRunning }
            }
            target.handleTeamsRestart()
            // `open -g` is the reliable way to relaunch without activating; NSWorkspace's
            // openApplication did not consistently start a terminated Teams here.
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-g", "-b", TeamsProcesses.bundleIdentifier]
            try? launch.run()
            launch.waitUntilExit()
            _ = AXPoll.wait(timeout: 90) { TeamsProcesses.isRunning }
            print("   Teams relaunched; waiting for it to settle…")
            _ = AXPoll.wait(timeout: 60) { !TeamsProcesses.webViewHelperPIDs().isEmpty }
            parkFocusAwayFromTeams()
            outcomes.append(statusCase("5. after restart", text: "♪ Gate 5 after restart"))
        } else {
            print("\n   (skipping restart case — pass --with-restart to include it)")
        }

        // Restore whatever the user had.
        print("\nrestoring original status…")
        if let originalStatus {
            _ = try? target.apply(status: originalStatus)
        } else {
            try? target.clearStatus()
        }
        let restored = try? target.readCurrentStatus()
        let restoreOK = restored == originalStatus
        outcomes.append(Outcome(name: "restore original status", passed: restoreOK,
                                detail: "now \(restored.map { "\"\($0)\"" } ?? "<none>")",
                                focusPreserved: nil))

        // Report.
        print("\n\u{1B}[1mResults\u{1B}[0m")
        print(String(repeating: "─", count: 76))
        for outcome in outcomes {
            let mark = outcome.passed ? "\u{1B}[32mPASS\u{1B}[0m" : "\u{1B}[31mFAIL\u{1B}[0m"
            var line = "  [\(mark)] \(outcome.name.padding(toLength: 28, withPad: " ", startingAt: 0))"
            if let focusPreserved = outcome.focusPreserved {
                line += focusPreserved ? " focus✓ " : " focus✗ "
            } else {
                line += "         "
            }
            line += outcome.detail
            print(line)
        }
        let failed = outcomes.filter { !$0.passed }
        let focusStolen = outcomes.filter { $0.focusPreserved == false }
        print(String(repeating: "─", count: 76))
        print("  \(outcomes.count - failed.count)/\(outcomes.count) passed"
              + (focusStolen.isEmpty ? ", focus preserved throughout" : ", \(focusStolen.count) STOLE FOCUS"))
        exit(failed.isEmpty && focusStolen.isEmpty ? 0 : 1)
    }
}
