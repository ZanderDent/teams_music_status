import CTeamsWin
import Foundation
import TeamsMusicStatusCore

/// Whether Teams is in a state that can be automated, and what to do when it is not.
///
/// The Windows counterpart of the macOS `TeamsAccessibility` health model, and it exists
/// for the same reason: "Teams is running" is not one state but several, and each needs a
/// different repair. Two of them are less obvious than they look, and both were confirmed
/// on Windows rather than assumed from the macOS behaviour.
public enum TeamsHealth: Equatable, Sendable {
    /// Ready to automate.
    case healthy
    /// Teams is not running. Only the user can fix this.
    case notRunning
    /// Teams is running but has no visible window — closed to the tray.
    case noWindow
    /// The window is minimised.
    ///
    /// Restoring it is not cosmetic. A minimised Chromium window is treated as occluded
    /// and silently discards interactions, so an automation run against a minimised Teams
    /// fails in the most confusing way available: every call succeeds and nothing happens.
    case minimized
    /// The window is there but Chromium has not published the web content tree.
    ///
    /// Usually means the tree lapsed, and occasionally means a flyout from an interrupted
    /// run is still open — while one is, Chromium exposes only that dialog's subtree, so a
    /// stale flyout is indistinguishable from a dead tree until it is dismissed.
    case treeUnavailable

    init(code: Int32) {
        switch code {
        case TW_HEALTH_OK: self = .healthy
        case TW_HEALTH_NOT_RUNNING: self = .notRunning
        case TW_HEALTH_NO_WINDOW: self = .noWindow
        case TW_HEALTH_MINIMIZED: self = .minimized
        default: self = .treeUnavailable
        }
    }

    /// Whether this app can do anything about it, or whether only the user can.
    public var isRepairable: Bool {
        switch self {
        case .healthy: return true
        case .minimized, .treeUnavailable: return true
        case .notRunning, .noWindow: return false
        }
    }

    public var explanation: String {
        switch self {
        case .healthy: return "ready"
        case .notRunning: return "Microsoft Teams is not running."
        case .noWindow: return "Teams has no open window."
        case .minimized: return "The Teams window is minimised."
        case .treeUnavailable: return "Teams has not published its accessibility tree."
        }
    }
}

/// Reads health and performs the bounded, escalating repairs that are safe to perform
/// without disturbing the user.
public enum TeamsWindowsHealth {

    public static func current() -> TeamsHealth {
        TeamsHealth(code: tw_health())
    }

    /// Brings Teams to a state that can be automated, or reports why it cannot.
    ///
    /// Bounded and escalating, exactly like the macOS `ensureHealthy`. Every repair here
    /// is non-activating: nothing in this path is allowed to pull Teams to the foreground,
    /// which rules out the obvious `SW_RESTORE` and any "just focus it" shortcut.
    @discardableResult
    public static func ensureHealthy(attempts: Int = 4) throws -> TeamsHealth {
        for _ in 0..<attempts {
            let health = current()

            switch health {
            case .healthy:
                return .healthy

            case .notRunning, .noWindow:
                // Not ours to fix. Launching Teams would be a visible, unasked-for action,
                // and the macOS implementation treats the equivalent state the same way.
                throw TeamsWindowsError(code: TW_ERR_NO_TEAMS, stage: health.explanation)

            case .minimized:
                _ = tw_window_restore()
                _ = AXPoll.wait(timeout: 2.0) { current() != .minimized }

            case .treeUnavailable:
                // Dismiss a flyout an interrupted run may have left open, then re-establish
                // the tree. Escape first, because a stale dialog presents exactly as a dead
                // tree and re-opening alone would never clear it.
                _ = tw_post_key(Int32(TW_VK_ESCAPE))
                Thread.sleep(forTimeInterval: 0.3)
                _ = tw_open()
                _ = AXPoll.wait(timeout: 2.0) { current() == .healthy }
            }
        }

        let final = current()
        guard final == .healthy else {
            throw TeamsWindowsError(code: TW_ERR_TREE_UNAVAIL, stage: final.explanation)
        }
        return final
    }

    /// The installed Teams build, e.g. `26213.1006.5014.9784`.
    public static func teamsVersion() -> String? {
        var buffer = [UInt16](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBufferPointer { tw_teams_version($0.baseAddress, 64) }
        guard status == TW_OK else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let text = String(decoding: buffer[..<end], as: UTF16.self)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Focus instrumentation

/// Reads and parks the foreground window.
///
/// Used only to *prove* the automation leaves activation alone. `CONTRIBUTING.md` requires
/// any new interaction to demonstrate the frontmost application is unchanged, and on
/// Windows there is no equivalent of `NSWorkspace.frontmostApplication` in Foundation.
public enum WindowsFocus {

    /// The title of whatever window currently has the foreground.
    public static func frontmostTitle() -> String {
        var buffer = [UInt16](repeating: 0, count: 512)
        let status = buffer.withUnsafeMutableBufferPointer { tw_foreground_title($0.baseAddress, 512) }
        guard status == TW_OK else { return "<unknown>" }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end], as: UTF16.self)
    }

    public static func isTeamsFrontmost() -> Bool {
        frontmostTitle().localizedCaseInsensitiveContains("Microsoft Teams")
    }

    /// Moves the foreground to this process's own console.
    ///
    /// A "focus preserved" assertion means nothing if Teams already had the foreground
    /// when the case began, so the gate parks focus somewhere that is definitely not Teams
    /// before every measured interaction.
    @discardableResult
    public static func park() -> Bool {
        let ok = tw_park_focus() == TW_OK
        _ = AXPoll.wait(timeout: 2.0) { !isTeamsFrontmost() }
        return ok
    }
}
