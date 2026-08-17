import AppKit
import ApplicationServices
import Foundation

/// What state the Teams accessibility surface is in, most-broken first.
public enum TeamsHealth: Equatable, Sendable {
    case permissionMissing          // we don't hold the Accessibility TCC grant
    case notRunning                 // Teams isn't running at all
    case noWindow                   // running, but the last main window was closed
    case minimized                  // window exists but is in the Dock; AX reads work, clicks don't
    case treeUnavailable            // window present, but WebView2 hasn't published its a11y tree
    case signedOut                  // Teams is asking the user to authenticate — hands off
    case healthy                    // profile control resolves; automation can proceed

    public var canAutomate: Bool { self == .healthy }

    /// States that mean "the user has to do something in Teams". Automating against these
    /// is not merely futile, it actively gets in their way, so recovery must not try.
    public var isUserBusy: Bool { self == .signedOut }
}

public enum TeamsAccessibilityError: LocalizedError, Equatable {
    case permissionMissing
    case notRunning
    case couldNotReopenWindow
    case couldNotUnminimize
    case treeUnavailable(attempts: Int, elapsed: TimeInterval)
    case signedOut

    public var errorDescription: String? {
        switch self {
        case .permissionMissing:
            return "Accessibility permission is required to update the Teams status."
        case .notRunning:
            return "Microsoft Teams is not running."
        case .couldNotReopenWindow:
            return "Teams has no open window and it could not be reopened."
        case .couldNotUnminimize:
            return "Teams is minimized and could not be restored."
        case .treeUnavailable(let attempts, let elapsed):
            return String(format: "Teams' interface did not become available to the "
                          + "Accessibility API after %d attempts over %.0f seconds.", attempts, elapsed)
        case .signedOut:
            return "Teams is asking you to sign in. Syncing is paused until you're back in."
        }
    }
}

/// Detects and repairs the Teams accessibility surface.
///
/// ## The problem this solves
///
/// Teams 2.x renders its UI in Microsoft Edge WebView2. Chromium keeps its renderer
/// accessibility tree switched off until it believes an assistive technology is present,
/// so a freshly launched Teams exposes roughly 250 AX nodes — the native menu bar and
/// window chrome — and *no web content whatsoever*. No profile button, no status field.
///
/// Phase 0 established, on a freshly restarted Teams, that none of these work on their own:
/// waiting (7 minutes), `AXManualAccessibility` or `AXEnhancedUserInterface` on the app
/// element (both rejected outright), the same attributes on the helper pids, deep reads of
/// the helper trees, a System Events poke, or an `AXObserver` registration alone (90s).
///
/// What does work, reproducibly, is holding a *live* `AXObserver` on the Teams process —
/// pumped by a real run loop, exactly as a screen reader does — and then making contact
/// with the WebView helper processes. This class owns that observer for the lifetime of
/// the app and re-establishes it whenever Teams restarts.
///
/// Because the minimal sufficient trigger was never fully isolated, `ensureHealthy` does
/// not assume a single attempt suffices: it re-applies the whole sequence with escalating
/// waits until the *observable* success condition holds — the profile control resolves —
/// or a deadline expires, at which point it fails loudly rather than pretending.
public final class TeamsAccessibility {

    /// The success condition. Health is defined as "the element automation actually needs
    /// can be found", never as "an API returned success".
    private let profileSelector: AXSelector

    private let queue = DispatchQueue(label: "com.zanderdent.TeamsMusicStatus.ax", qos: .utility)

    // Observer state, only touched on `observerThread`'s run loop or under `observerLock`.
    private let observerLock = NSLock()
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observerRunLoop: CFRunLoop?
    private var observerThread: Thread?

    public init(profileSelector: AXSelector = TeamsSelectors.profileButton) {
        self.profileSelector = profileSelector
    }

    deinit { teardownObserver() }

    // MARK: - Permission

    public static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show the "grant Accessibility" prompt. Returns the current state.
    /// Call this only in response to a user action — it is a system modal.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Health

    public func health() -> TeamsHealth {
        guard Self.hasAccessibilityPermission else { return .permissionMissing }
        guard let pid = TeamsProcesses.pid() else { return .notRunning }

        let app = AXElement(pid: pid)
        let windows = (app.rawAttribute(kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        if windows.isEmpty { return .noWindow }

        // A minimized window still exposes a full, readable tree — but Chromium will not
        // run click handlers for it, so automation silently does nothing. Treat as unhealthy.
        let allMinimized = windows.allSatisfy { window in
            (AXElement(window).rawAttribute(kAXMinimizedAttribute as String) as? NSNumber)?.boolValue == true
        }
        if allMinimized { return .minimized }

        // Check before the profile control, not after. When Teams puts up its sign-in
        // sheet the app shell frequently survives underneath, so the profile button still
        // resolves and this would otherwise report `.healthy` and let a write proceed —
        // which is precisely how the integration ended up fighting the user for the
        // sign-in screen. Window titles are one attribute read each, so this is cheap
        // enough to sit on the hot path.
        if windows.contains(where: { TeamsSelectors.titleIndicatesSignIn(AXElement($0).title) }) {
            return .signedOut
        }

        return profileSelector.find(in: app) != nil ? .healthy : .treeUnavailable
    }

    /// Cheap check used by hot paths that already know Teams is up.
    public func isTreeMaterialized() -> Bool {
        guard let pid = TeamsProcesses.pid() else { return false }
        return profileSelector.find(in: AXElement(pid: pid)) != nil
    }

    // MARK: - Recovery

    /// Bring the Teams accessibility surface to a state where automation can run.
    ///
    /// Never activates Teams. Every repair path here — reopening a closed window,
    /// un-minimizing, and materializing the tree — was verified in Phase 0 to leave the
    /// user's frontmost application untouched.
    public func ensureHealthy(timeout: TimeInterval = 90) throws {
        let started = Date()
        var attempts = 0

        while Date().timeIntervalSince(started) < timeout {
            attempts += 1
            switch health() {
            case .healthy:
                if attempts > 1 {
                    Log.accessibility.info("Teams accessibility recovered after \(attempts, privacy: .public) attempt(s)")
                }
                return

            case .permissionMissing:
                throw TeamsAccessibilityError.permissionMissing

            case .notRunning:
                throw TeamsAccessibilityError.notRunning

            case .signedOut:
                // Deliberately no repair. Every tool in this loop — Escape, AXRaise,
                // re-opening windows, the enabler — would interfere with someone trying
                // to type a password. Fail immediately and let the caller back off.
                Log.accessibility.info("Teams is showing a sign-in window; standing down")
                throw TeamsAccessibilityError.signedOut

            case .noWindow:
                Log.accessibility.info("Teams has no open window; requesting reopen without activation")
                reopenWindowWithoutActivating()
                _ = AXPoll.wait(timeout: 8) { self.health() != .noWindow }

            case .minimized:
                Log.accessibility.info("Teams window is minimized; restoring without activation")
                unminimizeWindows()
                _ = AXPoll.wait(timeout: 8) { self.health() != .minimized }

            case .treeUnavailable:
                // A flyout left open by an interrupted run collapses the exposed tree to
                // just that dialog, which is indistinguishable from a dead tree until it
                // is dismissed. Always rule this out before assuming Chromium is at fault.
                if dismissStaleDialog() {
                    Log.accessibility.info("dismissed a stale Teams flyout; tree restored")
                    continue
                }
                Log.accessibility.info("Teams WebView accessibility tree unavailable; running enabler (attempt \(attempts, privacy: .public))")
                materializeTree()
                // Escalating patience: the tree usually appears within ~2s of helper
                // contact, but a Teams that is still signing in can take much longer.
                let patience = min(4.0 + Double(attempts) * 3.0, 15.0)
                _ = AXPoll.wait(timeout: patience) { self.isTreeMaterialized() }
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        if health() == .healthy { return }
        Log.accessibility.error("Teams accessibility could not be established after \(attempts, privacy: .public) attempts")
        throw TeamsAccessibilityError.treeUnavailable(attempts: attempts, elapsed: elapsed)
    }

    /// If a Teams flyout/dialog is hiding the rest of the tree, press Escape until the
    /// profile control comes back. Returns true when this actually fixed things.
    ///
    /// Cheap and safe to attempt: Escape on an already-idle Teams does nothing, and we
    /// only reach here when the profile control is already unreachable.
    private func dismissStaleDialog() -> Bool {
        guard let pid = TeamsProcesses.pid() else { return false }
        let app = AXElement(pid: pid)

        // Only bother if something dialog-like is actually present, otherwise this is a
        // genuinely empty tree and Escape will not help.
        let hasDialog = TeamsSelectors.profileDialog.find(in: app) != nil
            || TeamsSelectors.composeBox.find(in: app) != nil
            || TeamsSelectors.statusReadout.find(in: app) != nil
        guard hasDialog else { return false }

        // Escape has to actually reach the renderer. If the Teams window is occluded,
        // Chromium throttles it and drops the key event — exactly the failure seen with a
        // just-un-minimized window. Order the window in first; this does not activate the
        // app, so focus is still preserved.
        //
        // Without this, a flyout left open by an interrupted run wedges the integration
        // permanently: measured at 275 exposed nodes across 6 repair attempts over 105
        // seconds, recovering to 4321 the moment the window was raised.
        raiseWindowsWithoutActivating()

        let keyboard = AXKeyboard(pid: pid)
        for _ in 0..<3 {
            keyboard.send(.escape)
            if AXPoll.wait(timeout: 1.5, { self.isTreeMaterialized() }) { return true }
        }
        return false
    }

    // MARK: - The enabler

    /// Apply the assistive-technology signal that makes WebView2 publish its tree.
    ///
    /// Two halves, both required (each was proven insufficient alone in Phase 0):
    ///  1. a live `AXObserver` on the Teams process, driven by a real run loop;
    ///  2. AX contact with every `Microsoft Teams WebView` helper process.
    public func materializeTree() {
        guard let pid = TeamsProcesses.pid() else { return }
        ensureObserver(for: pid)
        touchWebViewHelpers()
    }

    /// Contact each WebView2 helper process over the Accessibility API.
    ///
    /// The `AXManualAccessibility` write is expected to fail (`attributeUnsupported` /
    /// `cannotComplete`) — it is retained because Chromium's detection keys off the
    /// *request*, not the result, and removing it changed observed behaviour in Phase 0.
    private func touchWebViewHelpers() {
        let helpers = TeamsProcesses.webViewHelperPIDs()
        Log.debug(Log.accessibility, "touching \(helpers.count) WebView helper process(es)")
        for helperPID in helpers {
            let element = AXElement(pid: helperPID)

            // The exact shape of the contact matters, and this mirrors the sequence proven
            // in Phase 0. Counting children alone is NOT enough: what appears to satisfy
            // Chromium's assistive-technology detection is a walk that *reads attributes*
            // off each node. So request the attribute list, then walk reading AXRole —
            // and do not cap the walk so tightly that it stops before reaching real nodes.
            var names: CFArray?
            AXUIElementCopyAttributeNames(element.raw, &names)
            readRolesDeeply(element, depth: 0, maxDepth: 12)

            // Expected to fail (attributeUnsupported / cannotComplete). Retained because
            // the detection keys off the request being made, not off its result.
            element.setAttribute("AXManualAccessibility", kCFBooleanTrue)
        }
    }

    /// Walk a helper's tree reading `AXRole` at every node.
    private func readRolesDeeply(_ element: AXElement, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        _ = element.role
        for child in element.children {
            readRolesDeeply(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    // MARK: - Observer lifecycle

    /// Create (or re-create, after a Teams restart) the long-lived observer.
    private func ensureObserver(for pid: pid_t) {
        observerLock.lock()
        let alreadyCorrect = (observedPID == pid && observer != nil)
        observerLock.unlock()
        if alreadyCorrect { return }

        teardownObserver()

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            // Intentionally empty. The point is that an observer EXISTS and is pumped by a
            // run loop; we do not need the notifications themselves.
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success,
              let created = newObserver else {
            Log.accessibility.error("AXObserverCreate failed for pid \(pid, privacy: .public)")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        // The full set matters. A five-notification variant failed to trigger the tree in
        // Phase 0 where this seven-notification set succeeded; the two extra registrations
        // (application-activated and created) are part of the working recipe.
        let notifications = [
            kAXFocusedUIElementChangedNotification,
            kAXValueChangedNotification,
            kAXWindowCreatedNotification,
            kAXApplicationActivatedNotification,
            kAXMainWindowChangedNotification,
            kAXCreatedNotification,
            kAXLayoutChangedNotification,
        ]
        for notification in notifications {
            AXObserverAddNotification(created, app, notification as CFString, nil)
        }

        observerLock.lock()
        observer = created
        observedPID = pid
        observerLock.unlock()

        startObserverRunLoop(for: created)
        // The helper contact that follows is only effective once the observer's run loop
        // is actually pumping, so do not race past thread start-up.
        _ = AXPoll.wait(timeout: 2.0, interval: 0.05) {
            self.observerLock.lock(); defer { self.observerLock.unlock() }
            return self.observerRunLoop != nil
        }
        Log.accessibility.info("AXObserver established on Teams pid \(pid, privacy: .public)")
    }

    /// Run the observer's source on a dedicated thread with its own run loop.
    ///
    /// A screen reader keeps its observer pumped continuously; so do we. This replaces the
    /// "pump the run loop for ten seconds" step from the Phase 0 spike with a permanent
    /// equivalent, which is both simpler and strictly stronger.
    private func startObserverRunLoop(for observer: AXObserver) {
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.observerLock.lock()
            self?.observerRunLoop = runLoop
            self?.observerLock.unlock()

            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            // A port-less run loop returns immediately, so keep a timer installed to hold it.
            let keepAlive = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3600, 3600, 0, 0) { _ in }
            CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
            CFRunLoopRun()
        }
        thread.name = "com.zanderdent.TeamsMusicStatus.axobserver"
        thread.qualityOfService = .utility
        thread.start()
        observerLock.lock()
        observerThread = thread
        observerLock.unlock()
    }

    public func teardownObserver() {
        observerLock.lock()
        let runLoop = observerRunLoop
        observer = nil
        observedPID = nil
        observerRunLoop = nil
        observerThread = nil
        observerLock.unlock()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// Called when Teams is seen to have restarted, so the next `ensureHealthy` rebuilds
    /// the observer against the new process.
    public func handleTeamsRestart() {
        Log.accessibility.info("Teams restart detected; resetting accessibility observer")
        teardownObserver()
    }

    // MARK: - Window repair

    /// Reopen the Teams main window WITHOUT bringing Teams to the foreground.
    ///
    /// `NSWorkspace.openApplication` with `activates = false` delivers a reopen request
    /// through LaunchServices, which AppKit turns into `applicationShouldHandleReopen`.
    /// Preferred over the AppleScript `reopen` verb used in the Phase 0 spike because it
    /// needs no Apple Events (Automation) permission — one fewer TCC prompt for the user.
    private func reopenWindowWithoutActivating() {
        guard let url = TeamsProcesses.applicationURL() else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Log.accessibility.error("reopen request failed: \(error.localizedDescription, privacy: .public)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 8)

        if AXPoll.wait(timeout: 6) { self.health() != .noWindow } { return }

        // LaunchServices does not always deliver a reopen to an already-running app.
        // The Standard Suite `reopen` verb does, and Phase 0 verified it does not steal
        // focus. It costs an Automation (Apple Events) consent for Teams, which is why it
        // is the fallback rather than the first choice.
        Log.accessibility.info("LaunchServices reopen did not restore a window; trying the AppleScript reopen verb")
        let source = "tell application id \"\(TeamsProcesses.bundleIdentifier)\" to reopen"
        guard let script = NSAppleScript(source: source) else { return }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            Log.accessibility.error("AppleScript reopen failed (\(code, privacy: .public)); Teams may need to be opened manually")
        }
    }

    /// Restore every minimized Teams window, without activating the application.
    ///
    /// Clearing `AXMinimized` alone is **not sufficient**, and this was the subtlest bug in
    /// the whole target. The window comes back and the accessibility tree reads perfectly —
    /// `health()` reports `.healthy` — yet Chromium silently discards every click and key
    /// event, because it still considers the restored window occluded and has its renderer
    /// throttled. Measured: `AXPress` on the profile control returned `.success` once a
    /// second for eight seconds and never once opened the flyout.
    ///
    /// `AXRaise` orders the window in and un-throttles the renderer, after which activation
    /// works immediately. Critically it raises the *window* without activating the *app*,
    /// so the user's frontmost application and keyboard focus are untouched — verified by
    /// measurement, not assumption.
    private func unminimizeWindows() {
        guard let pid = TeamsProcesses.pid() else { return }
        let app = AXElement(pid: pid)
        guard let windows = app.rawAttribute(kAXWindowsAttribute as String) as? [AXUIElement] else { return }
        for window in windows {
            AXElement(window).setAttribute(kAXMinimizedAttribute as String, kCFBooleanFalse)
        }

        _ = AXPoll.wait(timeout: 6) {
            guard let refreshed = AXElement(pid: pid)
                .rawAttribute(kAXWindowsAttribute as String) as? [AXUIElement] else { return false }
            return refreshed.allSatisfy { window in
                (AXElement(window).rawAttribute(kAXMinimizedAttribute as String) as? NSNumber)?.boolValue != true
            }
        }

        raiseWindowsWithoutActivating()
    }

    /// Order the Teams windows in so Chromium resumes processing input. Does not activate
    /// the application.
    func raiseWindowsWithoutActivating() {
        // Logged because raising Teams is the most user-visible thing this app does to
        // someone else's window; if it happens on a normal update, that is a bug.
        Log.accessibility.info("raising the Teams window (recovery only)")
        guard let pid = TeamsProcesses.pid() else { return }
        guard let windows = AXElement(pid: pid)
            .rawAttribute(kAXWindowsAttribute as String) as? [AXUIElement] else { return }
        for window in windows {
            AXElement(window).performAction(kAXRaiseAction as String)
        }
        // The renderer needs a beat after being un-throttled; poll rather than guess.
        _ = AXPoll.wait(timeout: 3) { self.isTreeMaterialized() }
    }
}
