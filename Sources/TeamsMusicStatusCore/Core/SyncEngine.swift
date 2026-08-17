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
        /// Longest a write may be held back because the user is working in Teams.
        ///
        /// Writing while someone is typing in Teams risks stealing the keystrokes that
        /// drive the flyout, so the write waits for them to leave. It cannot wait forever
        /// though — someone who lives in Teams all day would never see their status
        /// update — so after this the write goes ahead on the normal verified background
        /// path, which does not take focus.
        public var frontmostDeferCap: TimeInterval

        public static let `default` = Configuration(debounce: 5, pauseGrace: 300)

        public init(debounce: TimeInterval = 5,
                    pauseGrace: TimeInterval = 300,
                    frontmostDeferCap: TimeInterval = 30) {
            self.debounce = debounce
            self.pauseGrace = pauseGrace
            self.frontmostDeferCap = frontmostDeferCap
        }
    }

    /// What Teams is doing, from the user's point of view rather than the tree's.
    public enum TeamsInteraction: Equatable, Sendable {
        /// Teams is in the background. Safe to drive.
        case available
        /// Teams is the frontmost app — the user is probably typing in it.
        case userIsInTeams
        /// Teams is asking the user to authenticate. Hands off, indefinitely.
        case signInRequired
        /// Every Teams window is in the Dock. Chromium will not run click handlers for a
        /// minimized window, so writing means restoring it — which throws Teams in front
        /// of whatever the user is doing. Wait for them to bring it back themselves.
        case minimized
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
        /// When a Teams-touching action was first held back because the user was in Teams.
        ///
        /// Deliberately measured from when a write became *wanted*, not from when Teams
        /// came to the front. Timing it from the latter would mean someone who had been
        /// in Teams for five minutes gets the next track written instantly, which is the
        /// exact collision the deferral exists to avoid.
        public var deferredSince: Date?

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

        /// Whether carrying this out drives the Teams UI. Only these can collide with a
        /// user who is working in Teams, so only these are ever deferred.
        var touchesTeams: Bool {
            switch self {
            case .write, .restore: return true
            case .doNothing, .reportManualOverride: return false
            }
        }
    }

    /// Everything the engine needs to decide, gathered by the coordinator.
    public struct Input: Sendable {
        public let presence: TrackPresence?
        /// `presence` rendered through the user's template. Nil when nothing is playing.
        public let rendered: String?
        /// What Teams currently shows, when it is cheaply known. Nil means "not observed
        /// this tick" — absence must never be mistaken for an empty status.
        public let observedTeamsStatus: String??
        /// Whether it is polite — and safe — to drive Teams right now.
        public let teamsInteraction: TeamsInteraction

        public init(presence: TrackPresence?,
                    rendered: String?,
                    observedTeamsStatus: String?? = nil,
                    teamsInteraction: TeamsInteraction = .available) {
            self.presence = presence
            self.rendered = rendered
            self.observedTeamsStatus = observedTeamsStatus
            self.teamsInteraction = teamsInteraction
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Advance the state machine one tick.
    /// Decide what to do, then decide whether now is a polite moment to do it.
    ///
    /// The deferral is applied *after* the decision rather than before, because whether a
    /// write is wanted is exactly what starts the clock. It is applied to a throwaway copy
    /// of the state, so holding an action back leaves no trace: `decide` mutates state on
    /// the assumption its action is carried out — `.restore` clears `lastWrittenByApp`,
    /// writes clear the pending candidate — and committing those while suppressing the
    /// action would silently lose the user's saved status.
    public func step(state: inout State, input: Input, now: Date) -> Action {
        var trial = state
        let action = decide(state: &trial, input: input, now: now)

        guard action.touchesTeams else {
            // Nothing wanted, so nothing is being held back: reset the clock.
            trial.deferredSince = nil
            state = trial
            return action
        }

        switch input.teamsInteraction {
        case .available:
            trial.deferredSince = nil
            state = trial
            return action

        case .signInRequired, .minimized:
            // Indefinite, and for the same reason in both cases: acting would require
            // taking the window off the user. State is left untouched so the write is
            // simply retried once Teams is usable again.
            return .doNothing

        case .userIsInTeams:
            let since = state.deferredSince ?? now
            guard now.timeIntervalSince(since) >= configuration.frontmostDeferCap else {
                state.deferredSince = since
                return .doNothing
            }
            // Waited long enough. Go ahead on the normal verified background path — it
            // does not take focus, so the worst case is a brief flyout, not a hijack.
            trial.deferredSince = nil
            state = trial
            return action
        }
    }

    private func decide(state: inout State, input: Input, now: Date) -> Action {
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
