import Foundation

/// The pure decision logic behind status syncing.
///
/// Deliberately free of I/O, timers, actors and Teams: given the current playback
/// reading, what the app last wrote, and what Teams currently shows, decide what should
/// happen next. That makes every rule here — debounce, pause grace, manual-override
/// detection, restore-on-stop — directly unit testable without a running Teams.
public struct SyncEngine {

    public struct Configuration: Equatable, Sendable {
        /// Minimum gap between two Teams writes.
        ///
        /// This is a **leading-edge** limit, not a trailing-edge debounce: the first
        /// change after a quiet period is written straight away, and only a *second*
        /// change arriving inside the window has to wait. A track change therefore shows
        /// up in Teams as soon as it is noticed, while skipping through ten tracks still
        /// produces one or two edits rather than ten.
        ///
        /// The earlier trailing-edge behaviour made every single change wait out the full
        /// window on top of the poll interval, which felt broken — "nothing is updating".
        public var debounce: TimeInterval
        /// How long playback may stay paused/absent before the user's previous status is
        /// put back. Resuming inside this window causes no Teams churn at all.
        public var pauseGrace: TimeInterval

        public static let `default` = Configuration(debounce: 5, pauseGrace: 300)

        public init(debounce: TimeInterval = 5, pauseGrace: TimeInterval = 300) {
            self.debounce = debounce
            self.pauseGrace = pauseGrace
        }
    }

    public struct State: Equatable, Sendable {
        /// The status the app most recently wrote to Teams, if any.
        public var lastWrittenByApp: String?
        /// The user's status from before the app first wrote anything.
        /// Double optional: `nil` = not captured yet; `.some(nil)` = captured, was empty.
        public var savedUserStatus: String??
        /// Candidate held back because a write happened too recently.
        public var pendingCandidate: String?
        public var pendingSince: Date?
        /// When the last write actually went to Teams. Drives the leading-edge limit.
        public var lastWriteAt: Date?
        /// When playback stopped or paused; drives the grace period.
        public var idleSince: Date?
        /// Set once a manual edit is seen. Latches until the user clears it.
        public var manualOverrideDetected = false

        public init() {}
    }

    public enum Action: Equatable, Sendable {
        case doNothing
        /// Write this status to Teams.
        case write(String)
        /// Put the user's pre-app status back (or clear, when they had none).
        case restore(String?)
        /// Teams shows something the app did not write — stop and tell the user.
        case reportManualOverride(found: String?)
    }

    /// Everything the engine needs to decide, gathered by the coordinator.
    public struct Input: Sendable {
        public let presence: TrackPresence?
        /// `presence` rendered through the user's template. Nil when nothing is playing.
        public let rendered: String?
        /// What Teams currently shows, when it is cheaply known. Nil means "not observed
        /// this tick" — absence must never be mistaken for an empty status.
        public let observedTeamsStatus: String??

        public init(presence: TrackPresence?, rendered: String?, observedTeamsStatus: String?? = nil) {
            self.presence = presence
            self.rendered = rendered
            self.observedTeamsStatus = observedTeamsStatus
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Advance the state machine one tick.
    public func step(state: inout State, input: Input, now: Date) -> Action {
        // 1. Manual-override detection, before anything else.
        //
        // Only meaningful once the app has written something: until then, whatever Teams
        // shows is the user's own status and is not an override. `observedTeamsStatus` is
        // a double optional so that "we didn't look this tick" stays distinct from "we
        // looked and it was empty".
        if let observed = input.observedTeamsStatus, let written = state.lastWrittenByApp {
            if observed != written {
                if !state.manualOverrideDetected {
                    state.manualOverrideDetected = true
                    return .reportManualOverride(found: observed)
                }
                return .doNothing
            }
        }
        if state.manualOverrideDetected { return .doNothing }

        // 2. Nothing playing, or paused.
        let isActive = input.presence?.isPlaying == true && input.rendered?.isEmpty == false
        guard isActive else {
            state.pendingCandidate = nil
            state.pendingSince = nil

            // Nothing was ever written, so there is nothing to undo.
            guard state.lastWrittenByApp != nil else { return .doNothing }

            let idleSince = state.idleSince ?? now
            state.idleSince = idleSince
            guard now.timeIntervalSince(idleSince) >= configuration.pauseGrace else {
                return .doNothing  // still inside the grace window; leave Teams alone
            }
            let restoreTo = state.savedUserStatus ?? nil
            state.lastWrittenByApp = nil
            state.idleSince = nil
            return .restore(restoreTo)
        }

        // 3. Playing.
        state.idleSince = nil
        guard let rendered = input.rendered else { return .doNothing }

        // Already showing exactly this.
        if rendered == state.lastWrittenByApp {
            state.pendingCandidate = nil
            state.pendingSince = nil
            return .doNothing
        }

        // Leading edge: if nothing was written recently, publish immediately. This is
        // what makes a track change appear in Teams as soon as it is noticed.
        let sinceLastWrite = state.lastWriteAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if sinceLastWrite >= configuration.debounce {
            state.pendingCandidate = nil
            state.pendingSince = nil
            return .write(rendered)
        }

        // A write happened very recently, so hold this one until the window passes. Only
        // the newest candidate survives — skipping five tracks writes the fifth, not all five.
        state.pendingCandidate = rendered
        state.pendingSince = state.pendingSince ?? now
        return .doNothing
    }

    /// Record that a write landed. Also captures the user's original status the first
    /// time, which is what makes restore-on-disable possible.
    public static func recordWrite(state: inout State,
                                   status: String,
                                   previousTeamsStatus: String?,
                                   at now: Date = Date()) {
        if state.savedUserStatus == nil {
            state.savedUserStatus = .some(previousTeamsStatus)
        }
        state.lastWrittenByApp = status
        state.lastWriteAt = now
    }

    /// Decide what turning the integration off should do.
    ///
    /// The rule that matters: only put the old status back if Teams still shows what this
    /// app wrote. If the user has since typed something themselves, that is theirs and we
    /// leave it alone.
    public static func disableAction(state: State, currentTeamsStatus: String?) -> Action {
        guard let written = state.lastWrittenByApp else { return .doNothing }
        guard currentTeamsStatus == written else { return .doNothing }
        return .restore(state.savedUserStatus ?? nil)
    }
}
