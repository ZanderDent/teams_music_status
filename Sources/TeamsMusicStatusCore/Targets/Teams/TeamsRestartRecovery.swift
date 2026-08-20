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

        /// Consecutive failed status operations before Teams is presumed unusable,
        /// whatever its accessibility surface claims. Several, because a single AX
        /// failure is ordinary — controls miss activations, trees settle late, and
        /// treating one as "Teams is broken" would restart it constantly.
        public var operationFailuresBeforeRestart = 4
        /// And they must have persisted. A burst of four failures inside a few seconds is
        /// one bad moment; four spread across two minutes is a Teams that is not working.
        public var sustainedFailureInterval: TimeInterval = 120

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

    /// The general invariant, of which `decide` and `decideActivation` are special cases.
    ///
    /// Teams can be structurally healthy — running, windowed, tree exposed — and still be
    /// unable to complete a status operation. Observed 2026-08-20: the profile control
    /// refused AXPress, Return and Space for four minutes straight while `health()`
    /// reported `healthy` throughout, so neither of the symptom-specific escalations
    /// applied and the app retried the same failing operation indefinitely.
    ///
    /// This is the backstop for that whole class: whatever the symptom, if the app cannot
    /// complete a Teams operation for a sustained period while there is genuinely
    /// something to sync, it escalates once to a bounded restart rather than looping.
    ///
    /// - Parameters:
    ///   - consecutiveOperationFailures: failed status reads/writes in a row. Reset by any
    ///     success, so intermittent working ticks can never accumulate toward a restart.
    ///   - secondsSinceFirstFailure: how long the current streak has persisted.
    ///   - hasSomethingToSync: no playback means no work, and Teams being unusable is not
    ///     a problem worth restarting an application over.
    ///   - recoveryInProgress: a restart or activation already owns the recovery.
    public static func decideSustainedFailureRestart(consecutiveOperationFailures: Int,
                                                    secondsSinceFirstFailure: TimeInterval,
                                                    hasSomethingToSync: Bool,
                                                    audioCaptureActive: Bool,
                                                    restartsSoFar: Int,
                                                    secondsSinceLastRestart: TimeInterval?,
                                                    recoveryInProgress: Bool = false,
                                                    policy: Policy = Policy()) -> Decision {
        guard !recoveryInProgress else {
            return .wait("a recovery operation is already in progress")
        }
        guard hasSomethingToSync else {
            return .wait("nothing to sync — Teams does not need to be usable right now")
        }
        guard consecutiveOperationFailures >= policy.operationFailuresBeforeRestart else {
            return .wait("status operations have not failed enough to call Teams broken "
                       + "(\(consecutiveOperationFailures)/\(policy.operationFailuresBeforeRestart))")
        }
        guard secondsSinceFirstFailure >= policy.sustainedFailureInterval else {
            return .wait("failures have not persisted long enough "
                       + "(\(Int(secondsSinceFirstFailure))s/\(Int(policy.sustainedFailureInterval))s)")
        }
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

    /// What a restart actually achieved. `open` returning success is not evidence Teams
    /// came back — observed 2026-08-20, when a restart quit Teams cleanly and left the
    /// machine with no Teams at all until it was relaunched by hand. Anything that treats
    /// a launch request as a completed relaunch is not a recovery mechanism.
    public enum RestartOutcome: Equatable, Sendable {
        /// A new Teams process is running. Whether it is *usable* is the caller's to
        /// establish, by running accessibility recovery and a real status operation.
        case relaunched
        /// Teams was not running, so there was nothing to restart and nothing to own.
        case notRunning
        /// Teams would not quit, even after being forced.
        case quitFailed
        /// Teams quit but could not be brought back. This is the state that must end in
        /// `recoveryExhausted` rather than another attempt.
        case relaunchFailed

        public var isRelaunched: Bool { self == .relaunched }
    }

    /// Quit Teams and bring it back, transactionally, verifying each step by process state
    /// rather than by return codes.
    ///
    /// The quit half runs exactly once. If Teams is already gone, only the launch half is
    /// retried — repeatedly quitting something that has already quit is how a recovery
    /// turns into the outage it was meant to fix.
    public static func restartTeams(quitGracePeriod: TimeInterval = 10,
                                    launchAttempts: Int = 3,
                                    launchTimeout: TimeInterval = 30) async -> RestartOutcome {
        guard let app = TeamsProcesses.runningApp() else {
            Log.accessibility.info("Teams is not running; nothing to restart and nothing to relaunch")
            return .notRunning
        }
        guard let url = TeamsProcesses.applicationURL() else {
            Log.accessibility.error("cannot locate Microsoft Teams to relaunch it; leaving it alone")
            return .quitFailed
        }

        // Remembered so a relaunch is confirmed by a *different* process, not by the old
        // one still lingering in the process table.
        let oldPID = app.processIdentifier
        Log.accessibility.error("restarting Teams (pid \(oldPID, privacy: .public)) — recovery has exhausted every in-place repair")

        app.terminate()
        if !(await waitUntil(quitGracePeriod, { TeamsProcesses.pid() != oldPID })) {
            Log.accessibility.info("Teams did not quit within \(Int(quitGracePeriod), privacy: .public)s; forcing")
            TeamsProcesses.runningApp()?.forceTerminate()
            if !(await waitUntil(5, { TeamsProcesses.pid() != oldPID })) {
                Log.accessibility.error("Teams could not be terminated; abandoning the restart")
                return .quitFailed
            }
        }

        // Launch-only retries. The quit above already happened and must not repeat.
        for attempt in 1...max(1, launchAttempts) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } catch {
                Log.accessibility.error("Teams launch attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            // A launch request is not a launch. Only a live process with a new pid is.
            if await waitUntil(launchTimeout, { TeamsProcesses.pid().map { $0 != oldPID } ?? false }) {
                Log.accessibility.info("Teams relaunched on attempt \(attempt, privacy: .public) (pid \(TeamsProcesses.pid() ?? -1, privacy: .public))")
                return .relaunched
            }
            Log.accessibility.error("Teams did not appear after launch attempt \(attempt, privacy: .public)")
        }

        Log.accessibility.error("Teams could not be relaunched after \(launchAttempts, privacy: .public) attempts")
        return .relaunchFailed
    }

    private static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return condition()
    }
}
