import AppKit
import CoreAudio
import Foundation

/// Last-resort recovery for a Teams whose accessibility tree can never come back.
///
/// ## Why this exists
///
/// `ensureHealthy` can repair every state it was designed for — no window, minimized, a
/// stale flyout, a tree that has not materialized yet. It cannot repair a Chromium
/// renderer that has lost its accessibility tree for good, and after a WindowServer
/// restart that is exactly what happens: Teams survives, its window is there, and the
/// exposed tree is a four-element shell that no amount of `AXManualAccessibility` will
/// bring back.
///
/// Observed 2026-08-20. A userspace watchdog panic (configd missed its 180-second
/// check-in on a machine at load ~320) killed WindowServer; Teams restarted with it and
/// came back mute to the Accessibility API. The app then spent 45 minutes in a loop that
/// could not possibly succeed — seven attempts over 90 seconds, throw, back off, repeat —
/// while the one action that fixes it, restarting Teams, was not in its vocabulary.
/// Quitting and reopening Teams by hand restored it in seconds.
///
/// ## Why it is this cautious
///
/// Quitting somebody's Teams is the most disruptive thing this app can do, and the
/// project's governing rule is that making Teams unusable is far worse than failing to
/// update a status. So the escalation is deliberately hard to reach: in-place recovery
/// must have exhausted itself several times over, nothing may be capturing audio, and a
/// Teams that dies again on relaunch must not be able to turn this into a restart loop.
public enum TeamsRestartRecovery {

    // MARK: - Policy

    /// Pure so the whole escalation can be tested without a Teams, a microphone or a clock.
    public struct Policy: Equatable, Sendable {
        /// Consecutive `treeUnavailable` failures before a restart is considered. Each one
        /// is already ~90 seconds of `ensureHealthy` trying everything else, so three is
        /// roughly five minutes of hard failure before anything disruptive happens.
        public var failuresBeforeRestart = 3
        /// Minimum gap between restarts. Long enough that a Teams which is simply slow to
        /// come back is never restarted twice for the same outage.
        public var cooldown: TimeInterval = 15 * 60
        /// Hard cap per app launch. If Teams is broken in some way a restart cannot fix,
        /// the app must give up rather than keep killing it.
        public var maxRestarts = 3

        /// Consecutive persistent-`noWindow` results before Teams may be activated.
        /// Lower than the restart threshold because activation is far cheaper — a second
        /// of Teams in front, then focus handed back — but still more than one poll, so a
        /// window that is merely slow to appear is never grabbed at.
        public var failuresBeforeActivation = 2
        /// Activation is cheap, so its cooldown is shorter than a restart's — but it must
        /// still be impossible to flash Teams at the user repeatedly.
        public var activationCooldown: TimeInterval = 3 * 60
        public var maxActivations = 5

        public init() {}
    }

    public enum Decision: Equatable, Sendable {
        /// Take the escalating action — restart or activation, depending on which decision
        /// produced it.
        case proceed
        /// Carries why, so the log says which guard held rather than just "not yet".
        case wait(String)

        public var isGo: Bool { self == .proceed }
    }

    /// The whole escalation rule, in one place, with no side effects.
    ///
    /// - Parameters:
    ///   - consecutiveTreeFailures: `treeUnavailable` results in a row, reset by any success.
    ///   - restartsSoFar: restarts already performed this app launch.
    ///   - secondsSinceLastRestart: `nil` when none has happened yet.
    ///   - audioCaptureActive: something is using an input device — treat as a live call.
    public static func decide(consecutiveTreeFailures: Int,
                              restartsSoFar: Int,
                              secondsSinceLastRestart: TimeInterval?,
                              audioCaptureActive: Bool,
                              policy: Policy = Policy()) -> Decision {
        guard consecutiveTreeFailures >= policy.failuresBeforeRestart else {
            return .wait("in-place recovery has not been exhausted "
                       + "(\(consecutiveTreeFailures)/\(policy.failuresBeforeRestart))")
        }
        // Checked before the cap and the cooldown on purpose: never report "giving up" to
        // someone whose call is the only reason we are holding off.
        if audioCaptureActive {
            return .wait("audio capture is active — not interrupting a call")
        }
        guard restartsSoFar < policy.maxRestarts else {
            return .wait("restart cap reached (\(policy.maxRestarts)); a restart cannot fix this")
        }
        if let elapsed = secondsSinceLastRestart, elapsed < policy.cooldown {
            return .wait("restarted \(Int(elapsed))s ago; cooling down")
        }
        return .proceed
    }

    /// Whether Teams may be brought to the front to rebuild a window it has lost.
    ///
    /// Same shape as `decide`, same guards, different costs. Activation steals focus for
    /// about a second and gives it straight back, so it is allowed sooner and more often
    /// than a restart — but it is still gated on the polite routes having failed
    /// repeatedly, on nobody being in a call, and on a cap that makes a flashing loop
    /// impossible.
    ///
    /// - Parameters:
    ///   - consecutiveNoWindowFailures: persistent `couldNotReopenWindow` results in a row.
    ///     One is not enough: a window that is simply slow to appear must never be grabbed.
    ///   - restartInProgress: a restart already owns the recovery; do not compete with it.
    public static func decideActivation(consecutiveNoWindowFailures: Int,
                                        activationsSoFar: Int,
                                        secondsSinceLastActivation: TimeInterval?,
                                        audioCaptureActive: Bool,
                                        restartInProgress: Bool = false,
                                        policy: Policy = Policy()) -> Decision {
        guard !restartInProgress else {
            return .wait("a Teams restart is already in progress")
        }
        guard consecutiveNoWindowFailures >= policy.failuresBeforeActivation else {
            return .wait("the window may still appear on its own "
                       + "(\(consecutiveNoWindowFailures)/\(policy.failuresBeforeActivation))")
        }
        if audioCaptureActive {
            return .wait("audio capture is active — not interrupting a call")
        }
        guard activationsSoFar < policy.maxActivations else {
            return .wait("activation cap reached (\(policy.maxActivations)); Teams will not be brought forward again")
        }
        if let elapsed = secondsSinceLastActivation, elapsed < policy.activationCooldown {
            return .wait("activated \(Int(elapsed))s ago; cooling down")
        }
        return .proceed
    }

    // MARK: - Audio capture probe

    /// Whether any input device is running, which is the closest thing to a reliable
    /// "somebody is on a call" signal available without extra permissions.
    ///
    /// Deliberately conservative in both directions of failure: any CoreAudio error is
    /// reported as *active*, so an unreadable audio state delays recovery rather than
    /// risking a dropped meeting. A false positive costs a few minutes; a false negative
    /// costs somebody their call.
    public static var isAudioCaptureActive: Bool {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &device)
        guard deviceStatus == noErr, device != kAudioObjectUnknown else {
            Log.accessibility.info("could not read the default input device; assuming a call is active")
            return true
        }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running = UInt32(0)
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        let runningStatus = AudioObjectGetPropertyData(
            device, &runningAddress, 0, nil, &runningSize, &running)
        guard runningStatus == noErr else {
            Log.accessibility.info("could not read input device state; assuming a call is active")
            return true
        }
        return running != 0
    }

    // MARK: - The actuator

    /// Quit Teams and bring it back without stealing focus.
    ///
    /// Graceful first: `terminate()` lets Teams close its own windows and save state. Only
    /// a Teams that refuses to go within the grace period is forced, because a forced quit
    /// is what leaves the stale flyouts `dismissStaleDialog` exists to clean up.
    ///
    /// Returns whether Teams was running again afterwards.
    @discardableResult
    public static func restartTeams(gracePeriod: TimeInterval = 10,
                                    relaunchTimeout: TimeInterval = 30) async -> Bool {
        guard let app = TeamsProcesses.runningApp() else {
            Log.accessibility.info("Teams is not running; nothing to restart")
            return false
        }
        guard let url = TeamsProcesses.applicationURL() else {
            Log.accessibility.error("cannot locate Microsoft Teams to relaunch it; leaving it alone")
            return false
        }

        Log.accessibility.error("Teams' accessibility tree is unrecoverable in place; restarting Teams")
        app.terminate()

        let deadline = Date().addingTimeInterval(gracePeriod)
        while TeamsProcesses.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if TeamsProcesses.isRunning {
            Log.accessibility.info("Teams did not quit within \(Int(gracePeriod), privacy: .public)s; forcing")
            TeamsProcesses.runningApp()?.forceTerminate()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Relaunch without activating, exactly as the window-reopen path does: recovery
        // must never pull the user out of what they are doing.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            Log.accessibility.error("failed to relaunch Teams: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let relaunchDeadline = Date().addingTimeInterval(relaunchTimeout)
        while !TeamsProcesses.isRunning && Date() < relaunchDeadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let running = TeamsProcesses.isRunning
        Log.accessibility.info("Teams restart \(running ? "completed" : "did not bring Teams back", privacy: .public)")
        return running
    }
}
