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
             .teamsAccessibilityPermissionMissing, .teamsSelectorsChanged:
            return 30    // needs the user; no point hammering
        case .teamsNotRunning:
            return 15
        default:
            return settings.pollInterval
        }
    }

    private func tick() async {
        guard isEnabled else { return }

        // 1. Read the source.
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
        let rendered = presence.map { settings.template.render($0) }
        renderedStatus = (presence?.isPlaying == true) ? rendered : nil

        // 2. Decide.
        let input = SyncEngine.Input(presence: presence, rendered: rendered, observedTeamsStatus: nil)
        let action = engine.step(state: &engineState, input: input, now: Date())

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
                SyncEngine.recordWrite(state: &engineState, status: status,
                                       previousTeamsStatus: current)
                restoreStore.save(from: engineState)
                lastWarnings = target.lastWarnings
                consecutiveFailures = 0
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
            state = .spotifyPermissionMissing("Automation access to Spotify")
        }
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
        case PresenceTargetError.elementNotFound(let selector, _):
            // A missing selector after a Teams update is not a transient glitch; stop
            // automating and tell the user rather than thrashing against a changed UI.
            state = .teamsSelectorsChanged("Could not find '\(selector)'.")
            isEnabled = false
        default:
            consecutiveFailures += 1
            state = consecutiveFailures >= 3
                ? .teamsAccessibilityTreeUnavailable
                : .recovering
            Log.coordinator.error("Teams update failed: \(error.localizedDescription, privacy: .public)")
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
                Log.coordinator.info("Teams quit")
                self.target.handleTeamsRestart()
                self.knownTeamsPID = nil
                if self.isEnabled { self.state = .teamsNotRunning }
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

        teamsObservers = [terminated, launched]
    }

    // MARK: - Self-test

    /// Validate the Teams selectors, running only when the Teams build has changed since
    /// the last success.
    public func runSelfTestIfNeeded(force: Bool = false) async {
        let tracker = TeamsVersionTracker()
        let installed = TeamsProcesses.installedVersion()
        guard force || tracker.needsVerification(installed: installed) else { return }
        guard TeamsProcesses.isRunning else { return }

        do {
            let report = try await runOffMain { try TeamsSelfTest().run() }
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
