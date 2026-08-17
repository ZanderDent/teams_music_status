import AppKit
import ApplicationServices
import Foundation

/// Drives the Microsoft Teams custom status message through the macOS Accessibility API.
///
/// ## Invariants
///
/// * **No coordinates.** Nothing here reads or writes a screen position. Navigation is
///   entirely by `AXDOMIdentifier` and accessible name (see `TeamsSelectors`).
/// * **No unverified success.** `AXError.success` is treated as "the call was accepted",
///   never as "the UI changed". Every interaction asserts an observable state transition
///   and escalates to a verified fallback before failing loudly.
/// * **No focus theft.** Key events go to the Teams pid via `CGEvent.postToPid`; window
///   repair uses non-activating APIs. The user's frontmost app is never disturbed.
///
/// All work is serialized on one queue: the flyout is global UI state, so two concurrent
/// status writes would interleave and corrupt each other.
public final class TeamsAXTarget: PresenceTarget {

    public let id = "microsoft-teams"
    public let displayName = "Microsoft Teams"

    private let accessibility: TeamsAccessibility

    /// Clear-duration to request when writing a status. `Never` is the product default.
    public var clearAfter: String = "Never"
    /// Desired state of "Show when people message me". Never applied blindly — see
    /// `applyShowWhenMessaged`.
    public var showWhenMessaged: Bool = true

    /// Non-fatal problems from the most recent write, surfaced to the UI.
    public private(set) var lastWarnings: [String] = []

    public init(accessibility: TeamsAccessibility = TeamsAccessibility()) {
        self.accessibility = accessibility
    }

    // MARK: - Availability

    public func availability() -> TargetAvailability {
        switch accessibility.health() {
        case .healthy: return .ready
        case .permissionMissing: return .permissionMissing
        case .notRunning: return .appNotRunning
        case .noWindow: return .needsRecovery("Teams has no open window")
        case .minimized: return .needsRecovery("Teams is minimized")
        case .treeUnavailable: return .needsRecovery("Teams' interface is not exposed yet")
        case .signedOut: return .needsRecovery("Teams is signed out")
        }
    }

    /// Cheap enough for the poll loop, unlike `availability()`.
    public var isShowingSignIn: Bool { accessibility.isShowingSignIn() }

    public func prepare() throws {
        try TeamsUI.exclusive { try accessibility.ensureHealthy() }
    }

    public func handleTeamsRestart() {
        accessibility.handleTeamsRestart()
    }

    /// Run an automation step, and if it fails in a way that looks transient, repair the
    /// accessibility surface and try once more.
    ///
    /// Justified by measurement rather than superstition: a window that has just been
    /// un-minimized, or a Teams that has just relaunched, reports a perfectly readable
    /// accessibility tree while its renderer still drops activations. One verified retry
    /// after a fresh `ensureHealthy` converts those into successes instead of user-visible
    /// failures. Genuinely broken selectors still fail on the second attempt.
    private func withRecovery<T>(_ label: String, attempts: Int = 2, _ body: () throws -> T) throws -> T {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try body()
            } catch let error as PresenceTargetError {
                lastError = error
                guard attempt < attempts else { break }
                Log.teams.warning("\(label, privacy: .public) failed (attempt \(attempt, privacy: .public)): \(error.localizedDescription, privacy: .public); recovering")
                closeFlyout()
                try? accessibility.ensureHealthy()
                // Deliberately NOT raising the Teams window here. AXRaise does not steal
                // keyboard focus, but it does throw Teams in front of whatever the user
                // is looking at, and on a retry loop that reads as the app repeatedly
                // "foregrounding Teams" — reported as such during first-run testing.
                // Raising is confined to the paths that genuinely need it: restoring a
                // minimized window, and un-wedging a stale flyout.
            }
        }
        throw lastError ?? PresenceTargetError.activationFailed(control: label)
    }

    // MARK: - Element access

    private func appElement() throws -> AXElement {
        guard let pid = TeamsProcesses.pid() else { throw TeamsAccessibilityError.notRunning }
        return AXElement(pid: pid)
    }

    private func keyboard() throws -> AXKeyboard {
        guard let pid = TeamsProcesses.pid() else { throw TeamsAccessibilityError.notRunning }
        return AXKeyboard(pid: pid)
    }

    /// Subtree to search once the profile flyout is open.
    ///
    /// Searching from the application root costs ~650 ms, because the Teams accessibility
    /// tree is ~4300 nodes and every node needs an IPC round trip for its children plus
    /// two or three for the predicate. A status write performs fifteen to twenty searches,
    /// which is where an 11-second update actually went. Every control the editor needs
    /// lives inside the flyout dialog, so once that is open we search a subtree of a few
    /// hundred nodes instead of the whole app.
    private var flyoutScope: AXElement?

    /// Cache the flyout dialog so subsequent lookups are cheap.
    private func captureFlyoutScope() {
        guard flyoutScope == nil, let app = try? appElement() else { return }
        flyoutScope = TeamsSelectors.profileDialog.find(in: app, maxDepth: AXActivator.flyoutSearchDepth)
    }

    private func releaseFlyoutScope() { flyoutScope = nil }

    /// - Parameter scoped: false for controls that live *outside* the flyout, such as the
    ///   profile button itself.
    private func find(_ selector: AXSelector, scoped: Bool = true) -> AXElement? {
        if scoped, let scope = flyoutScope {
            if let hit = selector.find(in: scope) { return hit }
            // The dialog was torn down and rebuilt (Teams re-renders it freely); fall
            // back to a full search and re-capture.
            releaseFlyoutScope()
        }
        guard let app = try? appElement() else { return nil }
        return selector.find(in: app)
    }

    private func require(_ selector: AXSelector, stage: String) throws -> AXElement {
        guard let element = find(selector) else {
            Log.teams.error("selector '\(selector.name, privacy: .public)' not found while \(stage, privacy: .public) — \(selector.describedAs, privacy: .public)")
            throw PresenceTargetError.elementNotFound(selector: selector.name, stage: stage)
        }
        return element
    }

    // MARK: - Flyout navigation

    /// Open the profile flyout if it is not already open.
    private func openProfileFlyout() throws {
        // One search, not three.
        //
        // Searching for an element that is NOT present costs a full walk of the ~4300
        // node tree (~650 ms each), and the old check asked for three absent elements
        // before doing anything — two seconds of pure waste on every update. The dialog
        // sits near the front of the tree, so a depth-first search finds it quickly when
        // it is there, and its presence answers the same question.
        captureFlyoutScope()
        if flyoutScope != nil { return }

        guard let app = try? appElement(),
              let button = TeamsSelectors.profileButton.find(in: app) else {
            Log.teams.error("selector 'profileButton' not found while opening the profile menu")
            throw PresenceTargetError.elementNotFound(selector: "profileButton",
                                                     stage: "opening the profile menu")
        }
        // The wait condition is evaluated repeatedly, so it has to be cheap. Asking for
        // statusReadout OR setStatusItem meant two full-tree walks per poll — and one of
        // them is always absent, which is the worst case (~650 ms for a complete walk).
        // The dialog's own presence answers the same question in one search, and it sits
        // near the front of the tree so a depth-first hit is quick.
        let outcome = AXActivator.activate(button, keyboard: try keyboard(),
                                           timeout: 5, label: "profileButton") {
            TeamsSelectors.profileDialog.find(in: app, maxDepth: AXActivator.flyoutSearchDepth) != nil
        }
        guard outcome.didSucceed else {
            throw PresenceTargetError.activationFailed(control: "profile button")
        }
        captureFlyoutScope()
    }

    /// Open the status editor. Requires the flyout to be open.
    private func openStatusEditor() throws {
        if find(TeamsSelectors.composeBox) != nil { return }

        let entry: AXElement
        let label: String
        if let edit = find(TeamsSelectors.editStatusButton) {
            entry = edit; label = "editStatusButton"
        } else if let set = find(TeamsSelectors.setStatusItem) {
            entry = set; label = "setStatusItem"
        } else {
            throw PresenceTargetError.elementNotFound(
                selector: "editStatusButton|setStatusItem", stage: "opening the status editor")
        }

        let outcome = AXActivator.activate(entry, keyboard: try keyboard(),
                                           timeout: 5, label: label) { [self] in
            find(TeamsSelectors.composeBox) != nil
        }
        guard outcome.didSucceed else {
            throw PresenceTargetError.activationFailed(control: label)
        }
    }

    /// Dismiss *our* flyout without committing anything further.
    ///
    /// ## Never press Escape at a Teams that is showing something else
    ///
    /// This used to send Escape unconditionally, on the reasoning that Escape at an idle
    /// Teams is harmless. It is not, because Teams is not always idle when a write fails.
    ///
    /// When Teams puts up its sign-in sheet, the app shell — and the profile button —
    /// often survive underneath it, so the health check still reports `.healthy` and a
    /// write is attempted. Activating the profile button then fails, because a modal is
    /// up, and the failure path fired Escape three times per attempt: once from this
    /// method's `defer`, once from `withRecovery`, and once more on the retry. Escape went
    /// to the sheet rather than to a flyout, and closed it. With the poll loop retrying
    /// every three seconds, the user could not stay on the sign-in screen long enough to
    /// type a password — the integration made Teams unusable, which is far worse than
    /// failing to set a status.
    ///
    /// So: only ever close a flyout that is actually open. Dismissing anything else is
    /// not this app's business. The extra subtree search costs nothing on the success
    /// path, where the dialog is present and found near the front of the tree, and only
    /// happens at all on paths that were already failing.
    private func closeFlyout() {
        defer { releaseFlyoutScope() }
        guard let app = try? appElement() else { return }

        // Any of our surfaces, at full depth. Checking only `profileDialog` was too narrow:
        // Teams swaps that dialog for the editor once the status field is open, so a
        // failure there left the editor on screen, which wedges the tree and makes the
        // stale-dialog recovery raise the Teams window.
        guard TeamsSelectors.ourStatusSurfaces.contains(where: { $0.find(in: app) != nil }) else {
            Log.debug(Log.teams, "closeFlyout: none of our status UI is open — not sending Escape")
            return
        }
        guard let keys = try? keyboard() else { return }
        keys.send(.escape)
        _ = AXPoll.wait(timeout: 1.5) {
            TeamsSelectors.ourStatusSurfaces.allSatisfy { $0.find(in: app) == nil }
        }
    }

    // MARK: - Reading

    /// The status message Teams currently shows, or nil when none is set.
    ///
    /// Only the first line is the message: Teams appends `"Display until 8:27 AM"` as a
    /// second line whenever a clear duration is active.
    public func readCurrentStatus() throws -> String? {
        try TeamsUI.exclusive {
            try withRecovery("read status") { try readCurrentStatusOnce() }
        }
    }

    private func readCurrentStatusOnce() throws -> String? {
        try accessibility.ensureHealthy()
        try openProfileFlyout()
        defer { closeFlyout() }

        guard let readout = find(TeamsSelectors.statusReadout) else {
            // Flyout is open but there is no readout: that means no status is set.
            return find(TeamsSelectors.setStatusItem) != nil ? nil : nil
        }
        return Self.firstLine(of: readout.value)
    }

    /// Exposed for testing: Teams appends "Display until H:MM AM" as a second line.
    static func firstLine(of value: String?) -> String? {
        guard let value else { return nil }
        let line = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? value
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Writing

    public func apply(status: String) throws {
        try TeamsUI.exclusive {
            try withRecovery("apply status") { try applyOnce(status: status) }
        }
    }

    /// Phase timings, emitted when TMS_DEBUG=1. Latency here is user-visible: it is how
    /// long the Teams flyout sits open on screen.
    private func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let started = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.debug(Log.teams, "phase \(label): \(ms)ms")
        }
        return try body()
    }

    private func applyOnce(status: String) throws {
        lastWarnings = []

        try timed("ensureHealthy") { try accessibility.ensureHealthy() }

        let sanitized = UnicodeSanitizer.sanitize(status)
        if sanitized.wasModified {
            Log.teams.info("status text adjusted for delivery: \(sanitized.substituted, privacy: .public) substituted, \(sanitized.dropped, privacy: .public) dropped")
        }
        let target = UnicodeSanitizer.clamp(sanitized.text)
        guard !target.isEmpty else {
            try clearStatus()
            return
        }

        // Any early exit MUST close the flyout. A flyout left open collapses Teams'
        // exposed accessibility tree to just that dialog, which makes every subsequent
        // run look like a dead tree until something presses Escape.
        var committed = false
        defer { if !committed { closeFlyout() } }

        try timed("openFlyout") { try openProfileFlyout() }
        try timed("openEditor") { try openStatusEditor() }

        let compose = try require(TeamsSelectors.composeBox, stage: "locating the status field")
        try timed("replaceText") { try replaceText(in: compose, with: target) }

        timed("showWhenMessaged") { applyShowWhenMessaged() }
        try timed("clearAfter") { try applyClearAfter() }

        try timed("commit") { try commit(expecting: target) }
        committed = true   // commit() closes the flyout itself
    }

    /// Replace the compose box contents.
    ///
    /// The field is CKEditor 5 (`AXDOMClassList` contains `ck-editor__editable`), which
    /// keeps its own document model. Setting `AXValue`, `AXSelectedText` or
    /// `AXReplaceRangeWithText` all report `.success` and change nothing — Phase 0 tested
    /// each. Real key events are the only path CKEditor observes.
    private func replaceText(in field: AXElement, with text: String) throws {
        let keys = try keyboard()

        field.setFocused(true)
        _ = AXPoll.wait(timeout: 1.0) { field.bool(kAXFocusedAttribute as String) == true }

        // Select all, then delete. Flags are cleared explicitly on the delete because the
        // private event source latches ⌘ from the select-all.
        keys.send(.a, flags: .maskCommand)
        keys.send(.delete)
        // Wait only briefly for the field to look empty, and treat "reports its own
        // placeholder text as the value" as empty too.
        //
        // On this Teams build AXPlaceholderValue is nil while an emptied CKEditor reports
        // its prompt text as AXValue, so the old condition could never become true and
        // burned the full timeout on every single update. Correctness does not depend on
        // this wait at all — the typed text is verified against the field afterwards.
        let promptText = field.axDescription ?? field.placeholder
        _ = AXPoll.wait(timeout: 0.5) {
            let current = self.find(TeamsSelectors.composeBox)?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return current.isEmpty || current == promptText
        }

        // 6 ms is comfortably above what Chromium needs to keep ordering, and halves
        // the typing cost of a long track title.
        for character in text { keys.type(character); Thread.sleep(forTimeInterval: 0.006) }

        // Verify the compose box actually holds what we typed before committing.
        let landed = AXPoll.wait(timeout: 3.0) {
            self.find(TeamsSelectors.composeBox)?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) == text
        }
        guard landed else {
            let actual = find(TeamsSelectors.composeBox)?.value ?? "<unreadable>"
            Log.teams.error("compose box did not accept the text; read back \(Redact.status(actual), privacy: .public)")
            throw PresenceTargetError.verificationFailed(expected: text, actual: actual)
        }
    }

    /// Set "Show when people message me" — but only when its state can be read.
    ///
    /// Measured on Teams 26198.202.4929.7171: the checkbox is present and activatable,
    /// but its checked state is **not exposed at all**. `AXValue` is present and writable
    /// yet always reads as an empty string, `AXSelected` stays `0` across toggles, and no
    /// sibling or ancestor carries the state. (Phase 0 guessed this was an artifact of the
    /// force-enabled tree; it is not — it reproduces on a fully healthy tree.)
    ///
    /// Blind-toggling would be a coin flip that could just as easily turn the user's
    /// setting OFF, so when the state is unreadable we leave it alone and warn. The UI
    /// tells the user to tick it once in Teams by hand. Non-fatal by design.
    private func applyShowWhenMessaged() {
        guard let checkbox = find(TeamsSelectors.showWhenMessagedCheckbox) else {
            lastWarnings.append("Could not find the 'Show when people message me' checkbox.")
            Log.teams.warning("showWhenMessagedCheckbox not found")
            return
        }

        let raw = checkbox.value ?? ""
        guard raw == "0" || raw == "1" else {
            lastWarnings.append("'Show when people message me' could not be read, so it was left unchanged.")
            Log.teams.warning("showWhenMessaged state unreadable (AXValue=\"\(raw, privacy: .public)\"); leaving unchanged")
            return
        }

        let isOn = raw == "1"
        guard isOn != showWhenMessaged else { return }

        let want = showWhenMessaged ? "1" : "0"
        let outcome = AXActivator.activate(checkbox, keyboard: (try? keyboard()) ?? AXKeyboard(pid: 0),
                                           timeout: 2.5, label: "showWhenMessagedCheckbox") { [self] in
            find(TeamsSelectors.showWhenMessagedCheckbox)?.value == want
        }
        if outcome.didSucceed {
            Log.teams.info("'Show when people message me' set to \(self.showWhenMessaged, privacy: .public)")
        } else {
            lastWarnings.append("'Show when people message me' could not be changed.")
            Log.teams.warning("failed to toggle showWhenMessaged")
        }
    }

    /// Set the clear duration. Unlike the checkbox this is fatal if it fails, because a
    /// status that silently expires after an hour is a broken product.
    private func applyClearAfter() throws {
        guard let popup = find(TeamsSelectors.clearAfterPopup) else {
            Log.teams.warning("clearAfterPopup not found; leaving Teams' default in place")
            lastWarnings.append("Could not find the clear-duration control.")
            return
        }

        // Title carries the current value as a suffix: "Clear status message after Never".
        if popup.title?.hasSuffix(clearAfter) == true { return }

        let option = TeamsSelectors.clearAfterOption(clearAfter)
        let opened = AXActivator.activate(popup, keyboard: try keyboard(),
                                          timeout: 3, label: "clearAfterPopup") { [self] in
            find(option) != nil
        }
        guard opened.didSucceed, let optionElement = find(option) else {
            throw PresenceTargetError.clearDurationUnavailable(requested: clearAfter)
        }

        let chosen = AXActivator.activate(optionElement, keyboard: try keyboard(),
                                          timeout: 3, label: "clearAfterOption") { [self] in
            find(TeamsSelectors.clearAfterPopup)?.title?.hasSuffix(clearAfter) == true
        }
        guard chosen.didSucceed else {
            throw PresenceTargetError.clearDurationUnavailable(requested: clearAfter)
        }
        Log.teams.info("clear duration set to \(self.clearAfter, privacy: .public)")
    }

    /// Press Done and confirm Teams actually stored the value.
    private func commit(expecting expected: String) throws {
        let done = try require(TeamsSelectors.doneButton, stage: "saving the status")
        let committed = AXActivator.activate(done, keyboard: try keyboard(),
                                             timeout: 5, label: "doneButton") { [self] in
            find(TeamsSelectors.composeBox) == nil
        }
        guard committed.didSucceed else {
            throw PresenceTargetError.activationFailed(control: "Done")
        }

        // Read back from Teams' own readout. This is the only proof that matters.
        let readBack = AXPoll.waitForValue(timeout: 4.0) { [self] () -> String? in
            guard let readout = find(TeamsSelectors.statusReadout) else { return nil }
            return Self.firstLine(of: readout.value)
        }
        closeFlyout()

        guard let readBack else {
            Log.teams.error("could not read the status back after commit")
            throw PresenceTargetError.verificationFailed(expected: expected, actual: "<unreadable>")
        }
        guard readBack == expected else {
            Log.teams.error("post-commit mismatch: expected \(Redact.status(expected), privacy: .public), read \(Redact.status(readBack), privacy: .public)")
            throw PresenceTargetError.verificationFailed(expected: expected, actual: readBack)
        }
        Log.teams.info("status committed and verified: \(Redact.status(expected), privacy: .public)")
    }

    // MARK: - Clearing

    public func clearStatus() throws {
        try TeamsUI.exclusive {
            try withRecovery("clear status") { try clearStatusOnce() }
        }
    }

    private func clearStatusOnce() throws {
        try accessibility.ensureHealthy()
        try openProfileFlyout()

        guard let delete = find(TeamsSelectors.deleteStatusButton) else {
            closeFlyout()
            return  // nothing set; nothing to do
        }
        let outcome = AXActivator.activate(delete, keyboard: try keyboard(),
                                           timeout: 4, label: "deleteStatusButton") { [self] in
            find(TeamsSelectors.deleteStatusButton) == nil
        }
        closeFlyout()
        guard outcome.didSucceed else {
            throw PresenceTargetError.activationFailed(control: "Delete status message")
        }
        Log.teams.info("status cleared")
    }
}
