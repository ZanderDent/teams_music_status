import Foundation

/// Result of validating the Teams selectors against the installed Teams build.
public struct SelectorSelfTestReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let selector: String
        public let description: String
        public let stage: String
        public let found: Bool
        /// Missing but not disqualifying (e.g. the checkbox Teams sometimes hides).
        public let optional: Bool
    }

    public let teamsVersion: String?
    public let entries: [Entry]
    public let startedAt: Date

    public var failures: [Entry] { entries.filter { !$0.found && !$0.optional } }
    public var warnings: [Entry] { entries.filter { !$0.found && $0.optional } }
    public var passed: Bool { failures.isEmpty }

    /// Compact, paste-into-a-bug-report summary.
    public var summary: String {
        var lines = ["Teams selector self-test — version \(teamsVersion ?? "unknown")"]
        for entry in entries {
            let mark = entry.found ? "PASS" : (entry.optional ? "WARN" : "FAIL")
            lines.append("  [\(mark)] \(entry.selector) (\(entry.stage)) — \(entry.description)")
        }
        lines.append(passed ? "RESULT: passed" : "RESULT: \(failures.count) required selector(s) missing")
        return lines.joined(separator: "\n")
    }
}

/// Validates that every Teams control the automation depends on still exists.
///
/// Teams auto-updates frequently, and the selectors are tied to accessible names and DOM
/// ids Microsoft can change without notice. Rather than discovering that mid-write and
/// leaving a half-edited status behind, the app checks up front — on launch and whenever
/// the installed Teams version changes — and refuses to automate against a UI it no
/// longer recognises.
///
/// The self-test drives the real flyout, so it briefly opens and closes the profile menu.
/// It always dismisses with Escape and never commits.
public final class TeamsSelfTest {

    private let accessibility: TeamsAccessibility

    public init(accessibility: TeamsAccessibility = TeamsAccessibility()) {
        self.accessibility = accessibility
    }

    public func run() throws -> SelectorSelfTestReport {
        let startedAt = Date()
        let version = TeamsProcesses.installedVersion()
        try accessibility.ensureHealthy()

        guard let pid = TeamsProcesses.pid() else { throw TeamsAccessibilityError.notRunning }
        let app = AXElement(pid: pid)
        let keys = AXKeyboard(pid: pid)
        var entries: [SelectorSelfTestReport.Entry] = []

        func record(_ selector: AXSelector, stage: String, optional: Bool = false) -> Bool {
            let found = selector.find(in: app) != nil
            entries.append(.init(selector: selector.name,
                                 description: selector.describedAs,
                                 stage: stage,
                                 found: found,
                                 optional: optional))
            return found
        }

        defer {
            keys.send(.escape)
            _ = AXPoll.wait(timeout: 1.5) { TeamsSelectors.composeBox.find(in: app) == nil }
            keys.send(.escape)
        }

        // Stage 1 — the entry point, always present when the tree is healthy.
        guard record(TeamsSelectors.profileButton, stage: "idle") else {
            return SelectorSelfTestReport(teamsVersion: version, entries: entries, startedAt: startedAt)
        }

        // Stage 2 — open the flyout.
        if let button = TeamsSelectors.profileButton.find(in: app) {
            _ = AXActivator.activate(button, keyboard: keys, timeout: 5, label: "selfTest.profileButton") {
                TeamsSelectors.statusReadout.find(in: app) != nil
                    || TeamsSelectors.setStatusItem.find(in: app) != nil
            }
        }
        // Exactly one of these is present depending on whether a status is already set,
        // so neither is individually required.
        let hasReadout = record(TeamsSelectors.statusReadout, stage: "flyout open", optional: true)
        let hasSetItem = record(TeamsSelectors.setStatusItem, stage: "flyout open", optional: true)
        guard hasReadout || hasSetItem else {
            entries.append(.init(selector: "statusEntryPoint",
                                 description: "either statusReadout or setStatusItem must be present",
                                 stage: "flyout open", found: false, optional: false))
            return SelectorSelfTestReport(teamsVersion: version, entries: entries, startedAt: startedAt)
        }
        _ = record(TeamsSelectors.editStatusButton, stage: "flyout open", optional: true)

        // Stage 3 — open the editor.
        let entry = TeamsSelectors.editStatusButton.find(in: app) ?? TeamsSelectors.setStatusItem.find(in: app)
        if let entry {
            _ = AXActivator.activate(entry, keyboard: keys, timeout: 5, label: "selfTest.statusEntry") {
                TeamsSelectors.composeBox.find(in: app) != nil
            }
        }
        for selector in TeamsSelectors.editorSelectors {
            _ = record(selector, stage: "editor open",
                       optional: selector.name == "characterCounter")
        }
        // Teams hides this checkbox in some configurations; missing is a warning, not a failure.
        _ = record(TeamsSelectors.showWhenMessagedCheckbox, stage: "editor open", optional: true)

        let report = SelectorSelfTestReport(teamsVersion: version, entries: entries, startedAt: startedAt)
        if report.passed {
            Log.selfTest.info("selector self-test passed for Teams \(version ?? "unknown", privacy: .public)")
        } else {
            Log.selfTest.error("selector self-test FAILED for Teams \(version ?? "unknown", privacy: .public)")
            for failure in report.failures {
                Log.selfTest.error("  missing: \(failure.selector, privacy: .public) — \(failure.description, privacy: .public)")
            }
        }
        return report
    }
}

/// Remembers which Teams build last passed the self-test, so the check runs on upgrade
/// rather than on every launch. Stored locally in UserDefaults; never transmitted.
public struct TeamsVersionTracker {
    private static let key = "lastVerifiedTeamsVersion"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var lastVerifiedVersion: String? {
        get { defaults.string(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    /// True when we have never verified this exact Teams build.
    public func needsVerification(installed: String?) -> Bool {
        guard let installed else { return true }
        return lastVerifiedVersion != installed
    }

    public func recordSuccess(version: String?) {
        guard let version else { return }
        lastVerifiedVersion = version
    }
}
