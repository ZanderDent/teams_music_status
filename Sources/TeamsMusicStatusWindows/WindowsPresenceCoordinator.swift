import CTeamsWin
import Foundation
import TeamsMusicStatusCore

/// The I/O shell around `SyncEngine`: polling, threading, error classification and Teams
/// lifecycle. The Windows counterpart of `PresenceCoordinator`.
///
/// All the *rules* — debounce, pause grace, manual-override detection, save and restore —
/// live in `SyncEngine`, which is shared with macOS and unit tested. Nothing in this file
/// decides anything; it gathers inputs, hands them over, and carries out the answer.
///
/// Teams automation blocks for seconds at a time, so the loop runs on its own thread and
/// never on whichever thread drives the tray UI.
public final class WindowsPresenceCoordinator: @unchecked Sendable {

    // MARK: - Observable state

    public struct Status: Sendable, Equatable {
        public var isRunning = false
        public var lastPublished: String?
        public var lastError: String?
        public var manualOverride = false
        public var nowPlaying: String?
        public var targetAvailability: String = "unknown"
        /// Consecutive failed cycles. Drives the backoff and the tray icon's state.
        public var consecutiveFailures = 0
    }

    private let settings: WindowsSettings
    private let source: PresenceSource
    private let target: TeamsWindowsTarget

    private var engine: SyncEngine
    private var state = SyncEngine.State()

    private let lock = NSRecursiveLock()
    private var thread: Thread?
    private var shouldStop = false
    private var status = Status()

    /// Called whenever `status` changes, off the main thread. The tray app marshals.
    public var onStatusChange: (@Sendable (Status) -> Void)?

    public init(settings: WindowsSettings,
                source: PresenceSource,
                target: TeamsWindowsTarget = TeamsWindowsTarget()) {
        self.settings = settings
        self.source = source
        self.target = target
        self.engine = SyncEngine(configuration: settings.syncConfiguration)
    }

    public var currentStatus: Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    // MARK: - Lifecycle

    public func start() {
        lock.lock()
        guard thread == nil else { lock.unlock(); return }
        shouldStop = false
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "com.zanderdent.TeamsMusicStatus.sync"
        thread.stackSize = 1 << 20
        self.thread = thread
        lock.unlock()

        Log.coordinator.info("sync started")
        mutate { $0.isRunning = true }
        thread.start()
    }

    /// Stops the loop and, if the user's status is still what this app wrote, puts their
    /// original back.
    ///
    /// The "still ours" check is the point: someone who let the app set a status, replaced
    /// it by hand, and then turned sync off keeps their own text. Restoring unconditionally
    /// would overwrite it.
    public func stop(restore: Bool = true) {
        lock.lock()
        shouldStop = true
        let hadThread = thread != nil
        thread = nil
        lock.unlock()

        guard hadThread else { return }
        Log.coordinator.info("sync stopping")

        if restore {
            let current = try? target.readCurrentStatus()
            let action = SyncEngine.disableAction(state: snapshotState(), currentTeamsStatus: current)
            if case .restore(let original) = action {
                do {
                    if let original, !original.isEmpty {
                        try target.apply(status: original)
                    } else {
                        try target.clearStatus()
                    }
                    Log.coordinator.info("restored the status the user had before sync")
                } catch {
                    Log.coordinator.error("could not restore the original status: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        lock.lock(); state = SyncEngine.State(); lock.unlock()
        mutate { $0.isRunning = false; $0.lastPublished = nil; $0.manualOverride = false }
    }

    /// Clears the manual-override latch, so syncing resumes after the user has taken over
    /// and then asked for it back.
    public func resumeAfterManualOverride() {
        lock.lock()
        state.manualOverrideDetected = false
        state.lastWrittenByApp = nil
        lock.unlock()
        mutate { $0.manualOverride = false }
        Log.coordinator.info("manual override cleared by the user")
    }

    // MARK: - The loop

    private func loop() {
        while !stopRequested() {
            let started = Date()
            cycle()

            // Back off after repeated failures rather than hammering a Teams that is not
            // ready. Capped so recovery is still prompt once it is.
            let failures = currentStatus.consecutiveFailures
            let backoff = failures == 0 ? 0 : min(pow(2.0, Double(min(failures, 5))), 60)
            let interval = max(settings.pollInterval, 1) + backoff

            // Slept in slices so stopping is responsive rather than waiting out a long
            // backoff before noticing.
            let deadline = started.addingTimeInterval(interval)
            while Date() < deadline && !stopRequested() {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        Log.coordinator.info("sync loop ended")
    }

    private func stopRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return shouldStop
    }

    private func cycle() {
        // Configuration can change under us while the loop runs — the user editing the
        // template in Settings is the normal case — so it is re-read every tick rather
        // than captured at start.
        engine.configuration = settings.syncConfiguration

        // 1. What is playing?
        let presence: TrackPresence?
        do {
            presence = try readPresence()
        } catch {
            recordFailure(error)
            return
        }

        let rendered = presence.map {
            settings.template.render($0, maskProfanity: settings.maskProfanity)
        }
        mutate {
            $0.nowPlaying = presence.map { "\($0.trackName) — \($0.joinedArtists)" }
        }

        // 2. Is it safe and polite to drive Teams?
        let interaction = teamsInteraction()
        mutate { $0.targetAvailability = describe(interaction) }

        // 3. Read what Teams shows — but only when it is worth the cost.
        //
        // Opening the flyout takes seconds and is briefly visible, so it is not done every
        // tick. It is needed only once the app has written something, to notice the user
        // taking over. `nil` means "not observed", which the engine keeps distinct from
        // "observed and empty".
        var observed: String?? = nil
        if state.lastWrittenByApp != nil, interaction == .available {
            observed = .some(try? target.readCurrentStatus())
        }

        // 4. Decide.
        let input = SyncEngine.Input(presence: presence,
                                     rendered: rendered,
                                     observedTeamsStatus: observed,
                                     teamsInteraction: interaction)
        lock.lock()
        let action = engine.step(state: &state, input: input, now: Date())
        lock.unlock()

        if case .doNothing = action {
            mutate { $0.consecutiveFailures = 0; $0.lastError = nil }
            return
        }
        Log.coordinator.info("action: \(action.logLabel, privacy: .public)")

        // 5. Carry it out.
        do {
            switch action {
            case .write(let text):
                let previous = try? target.readCurrentStatus()
                try target.apply(status: text)
                lock.lock()
                SyncEngine.recordWrite(state: &state, status: text, previousTeamsStatus: previous)
                lock.unlock()
                mutate { $0.lastPublished = text; $0.lastError = nil; $0.consecutiveFailures = 0 }

            case .restore(let original):
                if let original, !original.isEmpty {
                    try target.apply(status: original)
                } else {
                    try target.clearStatus()
                }
                mutate { $0.lastPublished = nil; $0.lastError = nil; $0.consecutiveFailures = 0 }

            case .reportManualOverride(let found):
                Log.coordinator.notice("manual override detected; found \(Redact.status(found), privacy: .public)")
                mutate { $0.manualOverride = true }

            case .doNothing:
                break
            }
        } catch {
            recordFailure(error)
        }
    }

    /// Reads the source, treating "nothing is playing" as the normal state it is.
    private func readPresence() throws -> TrackPresence? {
        if let windows = source as? WindowsMediaSource { return try windows.read() }

        // Any other source is async. The loop already runs off the main thread, so
        // waiting here blocks nothing the user can see.
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<TrackPresence?, Error>!
        Task {
            do { result = .success(try await source.fetch()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    /// Whether it is safe — and polite — to drive Teams right now.
    private func teamsInteraction() -> SyncEngine.TeamsInteraction {
        if TeamsSelectors.titleIndicatesSignIn(teamsWindowTitles()) { return .signInRequired }

        switch TeamsWindowsHealth.current() {
        case .notRunning, .noWindow:
            // Nothing to drive. Reported as sign-in-style hands-off rather than as an
            // error, so the loop keeps polling quietly until Teams comes back.
            return .signInRequired
        case .minimized:
            return .minimized
        case .healthy, .treeUnavailable:
            return tw_teams_is_frontmost() == 1 ? .userIsInTeams : .available
        }
    }

    /// Every Teams window title, newline-joined, for the sign-in check.
    private func teamsWindowTitles() -> String? {
        var buffer = [UInt16](repeating: 0, count: 2048)
        let status = buffer.withUnsafeMutableBufferPointer { tw_teams_window_titles($0.baseAddress, 2048) }
        guard status == TW_OK else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let text = String(decoding: buffer[..<end], as: UTF16.self)
        return text.isEmpty ? nil : text
    }

    private func describe(_ interaction: SyncEngine.TeamsInteraction) -> String {
        switch interaction {
        case .available: return "ready"
        case .userIsInTeams: return "waiting — you are working in Teams"
        case .signInRequired: return "waiting — Teams is not available"
        case .minimized: return "waiting — Teams is minimised"
        }
    }

    private func recordFailure(_ error: Error) {
        Log.coordinator.error("cycle failed: \(error.localizedDescription, privacy: .public)")
        mutate {
            $0.lastError = error.localizedDescription
            $0.consecutiveFailures += 1
        }
    }

    private func snapshotState() -> SyncEngine.State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    private func mutate(_ body: (inout Status) -> Void) {
        lock.lock()
        var copy = status
        body(&copy)
        let changed = copy != status
        status = copy
        lock.unlock()
        if changed { onStatusChange?(copy) }
    }
}
