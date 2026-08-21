import CTeamsWin
import Foundation
import TeamsMusicStatusCore
import TeamsMusicStatusWindows

/// Hard Gate 0 acceptance matrix, Windows edition.
///
/// The counterpart of `Sources/tmsctl/GateRunner.swift`, and it answers the same two
/// questions against the real installed Teams: is status automation deterministic in every
/// window state the product has to survive, and is the user's foreground window ever
/// disturbed.
///
/// `CONTRIBUTING.md` requires a gate result line in any pull request that adds an
/// interaction, and requires new interactions to prove the frontmost application is
/// unchanged. This is what produces that proof on Windows.
///
/// Run with `tmswinctl gate`.
struct GateRunner {
    let target: TeamsWindowsTarget

    struct Outcome {
        let name: String
        let passed: Bool
        let detail: String
        /// Nil where the case does not involve an interaction that could steal focus.
        let focusPreserved: Bool?
    }

    /// Runs one case: publish a status, verify the read-back, and check the foreground
    /// window is the same one that was there before.
    private func statusCase(_ name: String, text: String) -> Outcome {
        // A focus assertion is meaningless if Teams already had the foreground, so park it
        // somewhere that is definitely not Teams first.
        WindowsFocus.park()
        let before = WindowsFocus.frontmostTitle()

        do {
            try target.apply(status: text)
            let readBack = try target.readCurrentStatus()
            let after = WindowsFocus.frontmostTitle()
            let matched = readBack == text
            let detail = matched
                ? "read back \"\(readBack ?? "")\""
                : "MISMATCH: read \"\(readBack ?? "<nil>")\""
            return Outcome(name: name, passed: matched, detail: detail,
                           focusPreserved: before == after)
        } catch {
            return Outcome(name: name, passed: false,
                           detail: error.localizedDescription,
                           focusPreserved: before == WindowsFocus.frontmostTitle())
        }
    }

    func run(arguments: [String]) -> Never {
        var outcomes: [Outcome] = []

        print("\nHard Gate 0 — Teams automation acceptance (Windows)")
        print("Teams version: \(TeamsWindowsHealth.teamsVersion() ?? "unknown")")
        print("Health:        \(TeamsWindowsHealth.current().explanation)\n")

        // Record the user's real status so it can be put back at the end. Captured before
        // anything is written, and restored on every exit path below.
        WindowsFocus.park()
        let originalStatus = try? target.readCurrentStatus()
        print("original status: \(originalStatus.map { "\"\($0)\"" } ?? "<none>")\n")

        // 0. Selector self-test. Everything below is meaningless if the Teams UI moved.
        do {
            let report = try target.selectorReport()
            // statusReadout and setStatusItem are mutually exclusive — Teams shows one or
            // the other depending on whether a status is already set — so neither missing
            // on its own is a regression.
            let required = ["profileDialog"]
            let missing = report.filter { !$0.resolved && required.contains($0.name) }
            let entryPoints = report.filter {
                ["statusReadout", "setStatusItem", "editStatusButton"].contains($0.name) && $0.resolved
            }
            let passed = missing.isEmpty && !entryPoints.isEmpty
            outcomes.append(Outcome(
                name: "selector self-test",
                passed: passed,
                detail: passed
                    ? "\(report.count) selectors checked, \(report.filter(\.resolved).count) resolved"
                    : "missing: \(missing.map(\.name).joined(separator: ", "))",
                focusPreserved: nil))
            for entry in report where !entry.resolved {
                print("   (unresolved: \(entry.name))")
            }
        } catch {
            outcomes.append(Outcome(name: "selector self-test", passed: false,
                                    detail: error.localizedDescription, focusPreserved: nil))
        }

        // 1. Teams open and backgrounded — the primary case, and the one that matters most.
        outcomes.append(statusCase("1. backgrounded", text: "♫ Gate 1 backgrounded"))

        // 2. A second write straight after the first, as a track change would produce.
        outcomes.append(statusCase("2. consecutive update", text: "♫ Gate 2 second write"))

        // 3. Minimised, then recovered. Chromium treats a minimised window as occluded and
        //    discards interactions against it, so this case fails silently — every call
        //    reporting success — if the repair is missing.
        _ = tw_window_minimize()
        _ = AXPoll.wait(timeout: 4) { TeamsWindowsHealth.current() == .minimized }
        print("   (Teams minimized: health=\(TeamsWindowsHealth.current().explanation))")
        outcomes.append(statusCase("3. minimized → recovered", text: "♫ Gate 3 minimized"))

        // 4. Unicode that the macOS input path cannot deliver. CGEvent drops scalars above
        //    U+FFFF, which is why UnicodeSanitizer substitutes them; this records whether
        //    Windows shares that limit, since the answer decides whether the substitution
        //    is needed on this platform at all.
        let astral = UnicodeSanitizer.sanitize("🎵 Gate 4 astral").text
        outcomes.append(statusCase("4. sanitized unicode", text: astral))

        // Restore whatever the user had before the gate ran.
        print("\nrestoring original status…")
        WindowsFocus.park()
        do {
            if let originalStatus {
                try target.apply(status: originalStatus)
            } else {
                try target.clearStatus()
            }
        } catch {
            print("   restore failed: \(error.localizedDescription)")
        }
        let restored = try? target.readCurrentStatus()
        outcomes.append(Outcome(name: "restore original status",
                                passed: restored == originalStatus,
                                detail: "now \(restored.map { "\"\($0)\"" } ?? "<none>")",
                                focusPreserved: nil))

        // Report.
        print("\nResults")
        print(String(repeating: "─", count: 76))
        for outcome in outcomes {
            let mark = outcome.passed ? "PASS" : "FAIL"
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
