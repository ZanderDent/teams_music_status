import AppKit
import Combine
import Foundation

/// Owns the running integration: polls the selected source, decides what Teams should
/// show via `SyncEngine`, performs the write, and reports state to the UI.
///
/// All the *rules* live in `SyncEngine` (pure, unit tested). This type is the I/O shell
/// around them: timers, threading, Teams lifecycle observation and error classification.
@MainActor
public final class PresenceCoordinator: ObservableObject {

    // MARK: Published state

    @Published public private(set) var state: AppState = .disabled
    @Published public private(set) var currentPresence: TrackPresence?
    @Published public private(set) var renderedStatus: String?
    @Published public private(set) var lastWarnings: [String] = []
    @Published public private(set) var lastSelfTest: SelectorSelfTestReport?

    @Published public var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            Log.coordinator.info("isEnabled \(oldValue, privacy: .public) -> \(self.isEnabled, privacy: .public)")
            isEnabled ? start() : stop()
        }
    }

    // MARK: Collaborators

    private let target: TeamsAXTarget
    private let settings: AppSettings
    private var source: PresenceSource
    private var engine: SyncEngine
    private var engineState = SyncEngine.State()
    /// Survives relaunches so an app restart cannot make the app adopt its own leftover
    /// status as the user's baseline. See RestoreStateStore for the full rationale.
    private let restoreStore: RestoreStateStore

    private var pollTask: Task<Void, Never>?
    private var teamsObservers: [NSObjectProtocol] = []
    private var knownTeamsPID: pid_t?
    private var consecutiveFailures = 0
    /// Consecutive `treeUnavailable` results. Tracked separately from `consecutiveFailures`
    /// because it is the only failure a Teams restart can fix, and the only one allowed to
    /// escalate that far. Reset by any success.
    private var consecutiveTreeFailures = 0
    private var teamsRestarts = 0
    private var lastTeamsRestart: Date?
    private var isRestartingTeams = false
    /// Consecutive persistent `couldNotReopenWindow` results. Separate from the tree
    /// counter because the escalation is different: a missing window wants activation,
    /// a dead tree wants a restart.
    private var consecutiveNoWindowFailures = 0
    /// Failed Teams status operations in a row, whatever the symptom. Reset by any
    /// success, so intermittent working ticks never accumulate toward a restart.
    private var consecutiveOperationFailures = 0
    private var firstOperationFailureAt: Date?
    /// True only while a restart *this app initiated* is in flight. The terminate observer
    /// keys on it so a user quitting Teams is never mistaken for our own quit — intent is
    /// tracked, not inferred afterwards.
    private var ownsTeamsQuit = false
    private var teamsActivations = 0
    private var lastTeamsActivation: Date?
    private var isActivatingTeams = false
    /// Consecutive `elementNotFound` results. Reset by any successful read or write.
    private var consecutiveSelectorFailures = 0
    /// How many in a row before automatic updates are paused. Enough that a stale flyout
    /// or a momentarily wedged tree recovers first, few enough that a genuine Teams UI
    /// change is caught within seconds.
    static let selectorFailuresBeforeDisabling = 4
    /// Guards against the menu-bar panel's `.task` starting a second self-test each time
    /// it re-appears.
    private var isSelfTesting = false

    public init(target: TeamsAXTarget,
                source: PresenceSource,
                settings: AppSettings,
                restoreStore: RestoreStateStore = RestoreStateStore()) {
        self.target = target
        self.source = source
        self.settings = settings
        self.restoreStore = restoreStore
        self.engine = SyncEngine(configuration: settings.syncConfiguration)
        restoreStore.load(into: &engineState)
        if let carried = engineState.lastWrittenByApp {
            Log.coordinator.info("resuming ownership of a status written before relaunch: \(Redact.status(carried), privacy: .public)")
        }
        target.clearAfter = settings.clearAfter
        target.showWhenMessaged = settings.showWhenMessaged
        observeTeamsLifecycle()

        // Tidy up after a previous run before doing anything else.
        //
        // A crash, a force quit or an update installed mid-write can leave the Teams status
        // flyout open. Nothing used to close it: repair only happened as a side effect of
        // needing to write, and a relaunched instance usually has nothing to write because
        // the status it restored from disk already matches what is playing. The flyout then
        // sat open on screen indefinitely.
        //
        // Off the main actor because it touches the accessibility tree, and it is a no-op
        // whenever no flyout of ours is open.
        Task.detached(priority: .utility) { [target] in
            target.closeAbandonedFlyout()
        }
    }

    deinit {
        for observer in teamsObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Configuration

    public func setSource(_ newSource: PresenceSource) {
        source = newSource
        // Switching source can change the rendered text for the same audio, so drop the
        // debounce candidate rather than letting a stale one fire.
        engineState.pendingCandidate = nil
        engineState.pendingSince = nil
        Log.coordinator.info("source switched to \(newSource.displayName, privacy: .public)")
        refreshSoon()
    }

    public func applySettings() {
        engine.configuration = settings.syncConfiguration
        target.clearAfter = settings.clearAfter
        target.showWhenMessaged = settings.showWhenMessaged
    }

    /// Clear a latched manual override and resume automatic updates.
    public func resumeAfterManualOverride() {
        engineState.manualOverrideDetected = false
        // Whatever the user typed is now the status to restore later.
        engineState.savedUserStatus = nil
        engineState.lastWrittenByApp = nil
        restoreStore.clear()
        Log.coordinator.info("user resumed automatic status updates")
        refreshSoon()
    }

    // MARK: - Lifecycle

    private func start() {
        Log.coordinator.info("status sync enabled (source: \(self.source.displayName, privacy: .public))")
        state = .ready
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    private func stop() {
        Log.coordinator.info("status sync disabled")
        pollTask?.cancel()
        pollTask = nil
        Task { await restoreOnDisable() }
    }

    /// Turning sync off puts the user's original status back — but only if Teams still
    /// shows what this app wrote. Anything the user typed themselves is left alone.
    private func restoreOnDisable() async {
        defer { state = .disabled; currentPresence = nil; renderedStatus = nil }
        guard engineState.lastWrittenByApp != nil else { return }

        let current = try? await runOffMain { try self.target.readCurrentStatus() }
        let action = SyncEngine.disableAction(state: engineState, currentTeamsStatus: current ?? nil)
        guard case .restore(let previous) = action else {
            Log.coordinator.info("not restoring: Teams no longer shows the status this app wrote")
            return
        }
        await perform(.restore(previous))
        engineState = SyncEngine.State()
        restoreStore.clear()
    }

    /// Poll now rather than waiting out the current interval.
    public func refreshSoon() {
        guard isEnabled else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    // MARK: - Poll loop

    private func pollLoop() async {
        while !Task.isCancelled && isEnabled {
            await tick()
            let interval = currentPollInterval()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Back off when there is nothing to watch. Idle polling is the difference between a
    /// menu-bar utility and something that shows up in Activity Monitor.
    private func currentPollInterval() -> TimeInterval {
        switch state {
        case .spotifyRateLimited(let until):
            return max(settings.pollInterval, until.timeIntervalSinceNow + 1)
        case .noPlayback, .disabled:
            return settings.pollInterval * 3
        case .spotifyDisconnected, .spotifyAuthExpired, .spotifyPermissionMissing,
             .spotifyAutomationDenied,
             .teamsAccessibilityPermissionMissing, .teamsSelectorsChanged:
            return 30    // needs the user; no point hammering
        case .teamsNotRunning:
            return 15
        case .teamsMinimized:
            // Short enough to resume promptly when the window comes back, long enough not
            // to poll Teams constantly while nobody is looking at it.
            return 10
        case .teamsSignedOut:
            // Long, and deliberately so. The user is typing a password into Teams; every
            // poll is another chance to search its tree while they do. Checking every 20
            // seconds still picks sign-in back up promptly without hovering.
            return 20
        case .recovering, .teamsAccessibilityTreeUnavailable:
            // Back off as failures repeat rather than retrying at full rate forever. A
            // fixed 3-second retry against a Teams that is busy or broken is how this app
            // turned one problem into a persistent nuisance.
            //
            // The ceiling is five minutes, not one. When Teams keeps accepting the UI
            // interaction and then not storing the status, the cause is on Teams' side —
            // a stale session, a dropped connection — and no amount of retrying fixes it.
            // Continuing to drive its flyout every minute while the user works is the
            // behaviour that made this app feel like it was breaking Teams.
            return Self.backoffInterval(base: settings.pollInterval,
                                        failures: consecutiveFailures,
                                        cap: Self.teamsFailureCooldown)
        default:
            return settings.pollInterval
        }
    }

    /// Ceiling for repeated Teams write failures. Long deliberately: past a handful of
    /// attempts the problem is not one this app can retry its way out of.
    nonisolated static let teamsFailureCooldown: TimeInterval = 300

    /// Exponential backoff, capped. Pure so it can be tested without a run loop.
    nonisolated static func backoffInterval(base: TimeInterval,
                                            failures: Int,
                                            cap: TimeInterval = 60) -> TimeInterval {
        guard failures > 1 else { return base }
        let scaled = base * pow(2.0, Double(min(failures - 1, 10)))
        return min(scaled, cap)
    }

    /// Whether it is a polite moment to drive Teams.
    ///
    /// Sign-in is checked first and outranks everything: a sign-in sheet often appears
    /// while Teams is *not* frontmost, and deferring for 30 seconds there would still
    /// mean typing into someone's authentication window.
    ///
    /// Cheap by construction — a bundle-identifier comparison and, at most, the window
    /// titles `health()` already reads — because this runs on every tick.
    private func currentTeamsInteraction() -> SyncEngine.TeamsInteraction {
        if target.isShowingSignIn { return .signInRequired }
        if target.isMinimized { return .minimized }
        return TeamsProcesses.isFrontmost ? .userIsInTeams : .available
    }

    private func tick() async {
        guard isEnabled else { return }

        // 1. Read the source.
        //
        // A failed read returns *before the engine is stepped*, and that is the resilience
        // mechanism: the engine never sees a reading at all, so its idle clock does not
        // start, `lastWrittenByApp` is untouched, and whatever is on Teams stays there.
        // One failed Apple Event therefore cannot begin winding down toward restoring the
        // user's previous status. It takes a genuine observation of silence — Spotify
        // stopped, or not running — to do that.
        let presence: TrackPresence?
        do {
            presence = try await source.fetch()
            consecutiveFailures = 0
        } catch let error as PresenceSourceError {
            handleSourceError(error)
            return
        } catch is CancellationError {
            return
        } catch {
            state = .spotifyUnreachable(error.localizedDescription)
            return
        }

        currentPresence = presence
        let rendered = presence.map {
            settings.template.render($0, maskProfanity: settings.maskProfanity)
        }
        renderedStatus = (presence?.isPlaying == true) ? rendered : nil

        // 2. Decide.
        let input = SyncEngine.Input(presence: presence,
                                     rendered: rendered,
                                     observedTeamsStatus: nil,
                                     teamsInteraction: currentTeamsInteraction())
        let action = engine.step(state: &engineState, input: input, now: Date())
        Log.debug(Log.coordinator, "tick: enabled=\(self.isEnabled) source=\(self.settings.sourceKind.rawValue) "
                  + "playing=\(presence?.isPlaying == true) interaction=\(input.teamsInteraction) "
                  + "override=\(self.engineState.manualOverrideDetected) owns=\(self.engineState.lastWrittenByApp != nil) "
                  + "action=\(action.logLabel)")

        // 3. Act.
        switch action {
        case .doNothing:
            reflectIdleState(presence: presence)
        case .write, .restore:
            await perform(action)
        case .reportManualOverride(let found):
            state = .manualOverrideDetected(found)
        }
    }

    private func reflectIdleState(presence: TrackPresence?) {
        if engineState.manualOverrideDetected {
            state = .manualOverrideDetected(nil)
        } else if presence?.isPlaying == true {
            state = .ready
        } else {
            state = .noPlayback
        }
    }

    // MARK: - Performing actions

    private func perform(_ action: SyncEngine.Action) async {
        switch action {
        case .doNothing, .reportManualOverride:
            return

        case .write(let status):
            state = .syncing
            do {
                // Read what Teams shows first. This is also the manual-override check: if
                // it is not what we last wrote, the user has taken over and we stop.
                let current = try await runOffMain { try self.target.readCurrentStatus() }
                if let written = engineState.lastWrittenByApp, current != written {
                    engineState.manualOverrideDetected = true
                    state = .manualOverrideDetected(current)
                    // The user owns the status now, so stop claiming it across relaunches.
                    restoreStore.clear()
                    Log.coordinator.info("manual status edit detected; pausing automatic updates")
                    return
                }

                try await runOffMain { try self.target.apply(status: status) }
                // What Teams actually holds, not what we asked for: sanitisation and
                // clamping can change the text, and recording the request instead made
                // the next poll see a mismatch and declare a manual override.
                let written = target.lastAppliedStatus ?? status
                SyncEngine.recordWrite(state: &engineState, status: written,
                                       previousTeamsStatus: current, at: Date())
                restoreStore.save(from: engineState)
                lastWarnings = target.lastWarnings
                clearFailureStreaks()
                state = .ready
                Log.coordinator.info("Teams status updated: \(Redact.status(status), privacy: .public)")
            } catch {
                handleTargetError(error)
            }

        case .restore(let previous):
            state = .syncing
            do {
                if let previous, !previous.isEmpty {
                    try await runOffMain { try self.target.apply(status: previous) }
                    Log.coordinator.info("restored the previous Teams status")
                } else {
                    try await runOffMain { try self.target.clearStatus() }
                    Log.coordinator.info("cleared the Teams status")
                }
                restoreStore.clear()
                state = .noPlayback
            } catch {
                handleTargetError(error)
            }
        }
    }

    /// Teams automation is synchronous and blocking; keep it off the main actor so the
    /// menu bar stays responsive during the two-to-four second flyout dance.
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Error handling

    private func handleSourceError(_ error: PresenceSourceError) {
        // Source failures were previously silent in the logs, which made diagnosing a
        // stuck integration guesswork.
        Log.spotify.error("source read failed: \(error.localizedDescription, privacy: .public)")
        switch error {
        case .notAuthorized:
            state = .spotifyDisconnected
        case .authorizationExpired:
            state = .spotifyAuthExpired
        case .permissionsMissing(let detail):
            state = .spotifyPermissionMissing(detail)
        case .rateLimited(let retryAfter):
            state = .spotifyRateLimited(until: Date().addingTimeInterval(retryAfter))
        case .network(let detail), .serviceError(_, .some(let detail)):
            consecutiveFailures += 1
            state = .spotifyUnreachable(detail)
        case .serviceError(let status, nil):
            consecutiveFailures += 1
            state = .spotifyUnreachable("Spotify returned HTTP \(status)")
        case .appNotRunning:
            state = .noPlayback
        case .automationPermissionDenied:
            state = .spotifyAutomationDenied
        case .appleEventFailure(let code, let message):
            // Deliberately NOT .noPlayback. A failed Apple Event says nothing about what
            // Spotify is playing, and treating it as silence starts the pause grace and
            // can end with the user's status being restored over a track that never
            // stopped.
            consecutiveFailures += 1
            state = .spotifyUnreachable("Apple Event error \(code): \(message)")
        case .timedOut(let seconds):
            consecutiveFailures += 1
            state = .spotifyUnreachable("Spotify did not answer within \(Int(seconds))s")
        case .parseFailure(let detail):
            // A shape we do not understand is a bug, not a playback state. Surface it.
            consecutiveFailures += 1
            state = .spotifyUnreachable("unreadable answer from Spotify: \(detail)")
        }
    }

    /// Escalate to restarting Teams when, and only when, nothing else can work.
    ///
    /// `ensureHealthy` has already tried every in-place repair several times over by the
    /// time this can fire — see `TeamsRestartRecovery` for why a restart is the only
    /// remaining move after a WindowServer restart takes Chromium's accessibility tree
    /// with it. The guards live in `TeamsRestartRecovery.decide`, which is pure; this
    /// method only supplies the facts and performs the action.
    private func considerRestartingTeams() {
        guard !isRestartingTeams else { return }

        let decision = TeamsRestartRecovery.decide(
            consecutiveTreeFailures: consecutiveTreeFailures,
            restartsSoFar: teamsRestarts,
            secondsSinceLastRestart: lastTeamsRestart.map { -$0.timeIntervalSinceNow },
            audioCaptureActive: TeamsRestartRecovery.isAudioCaptureActive)

        guard decision.isGo else {
            if case .wait(let reason) = decision {
                Log.coordinator.info("not restarting Teams: \(reason, privacy: .public)")
                state = Self.waitingState(for: reason, fallback: state)
            }
            return
        }

        performTeamsRestart()
    }

    /// Execute the restart. Separated from the decision so the symptom-specific path and
    /// the generic sustained-failure path share one implementation, one cap and one
    /// ownership flag rather than drifting apart.
    private func performTeamsRestart() {
        guard !isRestartingTeams else { return }
        isRestartingTeams = true
        teamsRestarts += 1
        lastTeamsRestart = Date()

        ownsTeamsQuit = true
        Task { [weak self] in
            let outcome = await TeamsRestartRecovery.restartTeams()
            await MainActor.run {
                guard let self else { return }
                self.isRestartingTeams = false
                self.ownsTeamsQuit = false
                // The observer is bound to the old process; without this the next
                // ensureHealthy would watch a pid that no longer exists.
                self.target.handleTeamsRestart()
                switch outcome {
                case .relaunched:
                    // A new process exists. Whether Teams is *usable* is established by the
                    // next tick doing a real status operation — a relaunch is not a fix
                    // until something actually succeeds, so the generic streak stands.
                    self.consecutiveTreeFailures = 0
                    self.consecutiveNoWindowFailures = 0
                    self.state = .teamsRestartedAutomatically
                    self.refreshSoon()
                case .notRunning:
                    // Teams went away between the decision and the action, or the user quit
                    // it. Not ours to bring back.
                    self.state = .teamsNotRunning
                case .quitFailed, .relaunchFailed:
                    // Teams is gone and will not come back, or would not go away. Retrying
                    // cannot help and looping is the failure this exists to prevent.
                    Log.coordinator.error("automatic recovery could not restore Teams (\(String(describing: outcome), privacy: .public))")
                    self.state = .recoveryExhausted
                }
            }
        }
    }

    /// Translate a "not yet" from the recovery policy into something the user can read,
    /// so the panel never sits on an indefinite "Reconnecting…" while the app is actually
    /// waiting on a call to end or a cooldown to expire.
    private static func waitingState(for reason: String, fallback: AppState) -> AppState {
        if reason.contains("call") { return .recoveryDeferredForCall }
        if reason.contains("cooling down") { return .recoveryCoolingDown }
        if reason.contains("cap reached") { return .recoveryExhausted }
        return fallback
    }

    /// Bring Teams forward to rebuild a window it has lost — the only place this app takes
    /// focus, and only after every polite route has failed repeatedly.
    ///
    /// `ensureHealthy` has already spent 90 seconds per failure calling
    /// `reopenWindowWithoutActivating`, which covers both LaunchServices and the Standard
    /// Suite `reopen` verb. A Teams relaunched into a windowless state answers both with
    /// success and no window, so without this the app waits forever for something that is
    /// never going to happen.
    private func considerActivatingTeams() {
        guard !isActivatingTeams, !isRestartingTeams else { return }

        let decision = TeamsRestartRecovery.decideActivation(
            consecutiveNoWindowFailures: consecutiveNoWindowFailures,
            activationsSoFar: teamsActivations,
            secondsSinceLastActivation: lastTeamsActivation.map { -$0.timeIntervalSinceNow },
            audioCaptureActive: TeamsRestartRecovery.isAudioCaptureActive,
            restartInProgress: isRestartingTeams)

        guard decision.isGo else {
            if case .wait(let reason) = decision {
                Log.coordinator.info("not activating Teams: \(reason, privacy: .public)")
                state = Self.waitingState(for: reason, fallback: state)
            }
            return
        }

        isActivatingTeams = true
        teamsActivations += 1
        lastTeamsActivation = Date()

        Task { [weak self] in
            guard let self else { return }
            // Off the main thread: activation waits on Teams rebuilding a window, and the
            // UI must not block on that.
            let recovered = (try? await self.runOffMain { [target] in
                target.activateToRestoreWindow()
            }) ?? false
            await MainActor.run {
                self.isActivatingTeams = false
                if recovered {
                    // Deliberately clears only the window-specific streak. The generic
                    // counter keeps running until a status operation actually completes:
                    // observed 2026-08-20, activation produced a window that vanished
                    // again within a second, and resetting on that "success" restarted the
                    // whole cycle instead of escalating.
                    self.consecutiveNoWindowFailures = 0
                    self.state = .recovering
                    self.refreshSoon()
                }
            }
        }
    }

    /// Clear every failure streak. Called on any successful Teams operation, so a single
    /// working tick undoes all accumulated suspicion.
    private func clearFailureStreaks() {
        consecutiveFailures = 0
        consecutiveSelectorFailures = 0
        consecutiveTreeFailures = 0
        consecutiveNoWindowFailures = 0
        consecutiveOperationFailures = 0
        firstOperationFailureAt = nil
    }

    /// Record a failed status operation and escalate if Teams has been unusable for long
    /// enough to stop believing it will fix itself.
    ///
    /// This is the general case behind the two symptom-specific escalations. It exists
    /// because Teams can report itself perfectly healthy and still refuse every control,
    /// and no amount of accessibility repair addresses that — the app was left retrying
    /// the same failing operation indefinitely.
    private func noteOperationFailure() {
        consecutiveOperationFailures += 1
        if firstOperationFailureAt == nil { firstOperationFailureAt = Date() }

        let decision = TeamsRestartRecovery.decideSustainedFailureRestart(
            consecutiveOperationFailures: consecutiveOperationFailures,
            secondsSinceFirstFailure: firstOperationFailureAt.map { -$0.timeIntervalSinceNow } ?? 0,
            // No playback means no work, and an unusable Teams is not worth restarting an
            // application over until there is actually something to put in it.
            hasSomethingToSync: renderedStatus != nil,
            audioCaptureActive: TeamsRestartRecovery.isAudioCaptureActive,
            restartsSoFar: teamsRestarts,
            secondsSinceLastRestart: lastTeamsRestart.map { -$0.timeIntervalSinceNow },
            recoveryInProgress: isRestartingTeams || isActivatingTeams)

        guard decision.isGo else {
            if case .wait(let reason) = decision {
                Log.coordinator.info("sustained-failure escalation held: \(reason, privacy: .public)")
                state = Self.waitingState(for: reason, fallback: state)
            }
            return
        }
        Log.coordinator.error("Teams has been unable to complete a status operation \(self.consecutiveOperationFailures, privacy: .public) times; restarting it")
        performTeamsRestart()
    }

    private func handleTargetError(_ error: Error) {
        lastWarnings = target.lastWarnings
        switch error {
        case TeamsAccessibilityError.permissionMissing:
            state = .teamsAccessibilityPermissionMissing
        case TeamsAccessibilityError.notRunning:
            state = .teamsNotRunning
        case TeamsAccessibilityError.treeUnavailable:
            state = .teamsAccessibilityTreeUnavailable
            consecutiveTreeFailures += 1
            // Also counted generically: the specialised escalation may act sooner, but if
            // it keeps nominally succeeding without the status operation ever completing,
            // the backstop beneath must still see a Teams that does not work.
            noteOperationFailure()
            considerRestartingTeams()
        case TeamsAccessibilityError.couldNotReopenWindow:
            // Teams is running with no window and the focus-preserving routes have all
            // failed. Escalate to activation first — it is cheaper than a restart — but
            // count it generically too, so a Teams whose window keeps vanishing again
            // eventually reaches the restart backstop instead of cycling here forever.
            state = .recovering
            consecutiveNoWindowFailures += 1
            noteOperationFailure()
            considerActivatingTeams()
        case TeamsAccessibilityError.signedOut:
            // Not a failure to fix. Teams wants the user, and the kindest thing this app
            // can do is get out of the way until they are done. Deliberately does not
            // count as a consecutive failure: this is an expected state, not a fault.
            state = .teamsSignedOut
        case PresenceTargetError.elementNotFound(let selector, _):
            // A missing selector usually means Teams changed its UI, and thrashing against
            // that helps nobody — but it is not always what happened, and this used to
            // switch syncing off permanently on the very first occurrence.
            //
            // A flyout left open by a crash or a force quit collapses Teams' exposed tree
            // to that dialog, so the profile button genuinely cannot be found for a moment.
            // That is transient and self-healing, and disabling on it left people with
            // "automatic updates are not turned on" and no idea why. Reported exactly that
            // way after an interrupted write.
            //
            // So it now takes a few consecutive failures. A real UI change fails every
            // time and still gets caught within seconds; a stale flyout resolves on the
            // next tick and never reaches the threshold.
            consecutiveSelectorFailures += 1
            if consecutiveSelectorFailures >= Self.selectorFailuresBeforeDisabling {
                Log.coordinator.error("selector '\(selector, privacy: .public)' missing \(self.consecutiveSelectorFailures, privacy: .public) times in a row; pausing automatic updates")
                state = .teamsSelectorsChanged("Could not find '\(selector)'.")
                isEnabled = false
            } else {
                Log.coordinator.warning("selector '\(selector, privacy: .public)' not found (\(self.consecutiveSelectorFailures, privacy: .public) in a row); retrying")
                state = .recovering
                noteOperationFailure()
            }
        default:
            // Everything that is not a recognised structural problem: a control that will
            // not activate, a status Teams would not accept, anything new. One of these is
            // ordinary; a sustained run of them means Teams is unusable regardless of what
            // its accessibility surface reports, and that is what escalates.
            consecutiveFailures += 1
            state = consecutiveFailures >= 3
                ? .teamsAccessibilityTreeUnavailable
                : .recovering
            Log.coordinator.error("Teams update failed: \(error.localizedDescription, privacy: .public)")
            noteOperationFailure()
        }
    }

    // MARK: - Teams lifecycle

    /// Watch Teams launching and quitting so a restart is handled without user action.
    private func observeTeamsLifecycle() {
        knownTeamsPID = TeamsProcesses.pid()
        let center = NSWorkspace.shared.notificationCenter

        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == TeamsProcesses.bundleIdentifier else { return }
            Task { @MainActor in
                guard let self else { return }
                self.target.handleTeamsRestart()
                self.knownTeamsPID = nil
                if self.ownsTeamsQuit {
                    // Our own restart is mid-flight and owns bringing Teams back. Say so
                    // rather than reporting it as the user's Teams having gone away.
                    Log.coordinator.info("Teams quit as part of an automatic restart")
                } else {
                    // The user quit Teams. Nothing in this app may resurrect it — the
                    // generic escalation is gated on Teams running, and the restart
                    // actuator refuses outright when it is not.
                    Log.coordinator.info("Teams was quit by the user; not relaunching")
                    self.clearFailureStreaks()
                    if self.isEnabled { self.state = .teamsNotRunning }
                }
            }
        }

        // Waking is not a Teams event, so nothing above catches it — but it is the other
        // way the accessibility observer ends up bound to a world that no longer exists.
        // The machine may have slept for days, Teams may have been restarted by an update
        // while the lid was shut, and the poll loop would otherwise carry on against a
        // stale observer until its next tick happened to fail. Rebuilding on wake is cheap
        // and turns a silent gap into an immediate re-read.
        let woke = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Log.coordinator.info("woke from sleep; re-establishing accessibility")
                self.target.handleTeamsRestart()
                // A sleep is not evidence Teams misbehaved, so the escalation counter starts
                // clean rather than carrying pre-sleep failures toward a restart.
                self.consecutiveTreeFailures = 0
                if self.isEnabled {
                    self.state = .recovering
                    self.refreshSoon()
                }
            }
        }

        let launched = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == TeamsProcesses.bundleIdentifier else { return }
            Task { @MainActor in
                guard let self else { return }
                Log.coordinator.info("Teams launched; re-establishing accessibility")
                self.target.handleTeamsRestart()
                self.knownTeamsPID = app.processIdentifier
                // A relaunched Teams has no memory of our status, and the status we last
                // wrote may or may not have survived. Re-assert from a clean slate.
                self.engineState.lastWrittenByApp = nil
                if self.isEnabled {
                    self.state = .recovering
                    self.refreshSoon()
                }
            }
        }

        teamsObservers = [terminated, launched, woke]
    }

    // MARK: - Self-test

    /// Validate the Teams selectors, running only when the Teams build has changed since
    /// the last success.
    public func runSelfTestIfNeeded(force: Bool = false) async {
        let tracker = TeamsVersionTracker()
        let installed = TeamsProcesses.installedVersion()
        guard force || tracker.needsVerification(installed: installed) else { return }
        guard TeamsProcesses.isRunning, !isSelfTesting else { return }

        isSelfTesting = true
        defer { isSelfTesting = false }

        do {
            // Skip rather than queue if a status write is in flight.
            guard let report = try await runOffMain({ try TeamsSelfTest().runIfIdle() }) else {
                Log.selfTest.info("Teams is busy; skipping the self-test for now")
                return
            }
            lastSelfTest = report
            if report.passed {
                tracker.recordSuccess(version: installed)
                return
            }

            // Turning automation off is the right response to a genuinely changed Teams
            // UI, and the wrong response to "we couldn't open the editor just now" —
            // which happens if Teams is busy or something else is driving it. Only the
            // former disables the product.
            let navigationOnly = report.failures.allSatisfy { $0.selector == "statusEditorNavigation" }
            if navigationOnly {
                Log.selfTest.warning("self-test could not navigate to the status editor; not disabling sync")
                state = .recovering
            } else {
                state = .teamsSelectorsChanged(
                    "Missing: \(report.failures.map(\.selector).joined(separator: ", ")).")
                isEnabled = false
            }
        } catch {
            Log.selfTest.error("self-test could not run: \(error.localizedDescription, privacy: .public)")
        }
    }
}
