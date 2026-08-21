import CTeamsWin
import Foundation
import TeamsMusicStatusCore

/// The Teams status message, driven through Windows accessibility.
///
/// The Windows counterpart of `TeamsAXTarget`, and it keeps that implementation's three
/// invariants, all of which turned out to matter just as much here:
///
/// **No coordinates.** Navigation is by DOM id or accessible name, through the shared
/// `TeamsSelectors`. Nothing reads a bounding rectangle.
///
/// **A return code is never evidence.** Measured against live Teams, UI Automation's
/// `ExpandCollapsePattern.Expand` reports `Collapsed` while the flyout is open, and its
/// `LegacyIAccessible.DoDefaultAction` returns success having done nothing at all. Every
/// interaction here is followed by re-reading the tree until the expected state appears.
///
/// **No focus theft.** Presses go through MSAA and keys are posted to the browser widget,
/// neither of which activates Teams. UI Automation's own `SetFocus` and `Expand` both pull
/// the window to the foreground, so neither is used.
public final class TeamsWindowsTarget: PresenceTarget, @unchecked Sendable {

    public init() {}

    public var id: String { "teams-windows" }
    public var displayName: String { "Microsoft Teams" }

    /// How long to wait for Teams to react before deciding it did not.
    private let settleTimeout: TimeInterval = 4.0

    /// Serialises Teams UI access within this process **and across processes**.
    ///
    /// `TeamsUI.exclusive` alone is not enough on Windows. The tray application and
    /// `tmswinctl` are separate processes, so running the diagnostics CLI while the app is
    /// syncing has one opening the flyout while the other presses Escape — and both then
    /// report that a control "did not respond to activation", which reads as a broken
    /// selector rather than as two programs fighting.
    ///
    /// The timeout is generous because the operation being waited on drives the Teams UI
    /// and legitimately takes seconds.
    private func exclusive<T>(_ body: () throws -> T) throws -> T {
        try TeamsUI.exclusive {
            let status = tw_ui_lock(25_000)
            guard status == TW_OK else {
                throw TeamsWindowsError(
                    code: status,
                    stage: "waiting for another Teams Music Status process to finish with Teams")
            }
            defer { tw_ui_unlock() }
            return try body()
        }
    }

    // MARK: - Lifecycle

    /// Opens (or re-opens) Chromium's web content tree.
    ///
    /// Not idempotent-and-cheap by accident: Chromium lets the tree lapse when no client is
    /// reading, so this is called before every operation rather than once at startup.
    private func ensureOpen() throws {
        let status = tw_open()
        guard status == TW_OK else {
            // Opening failed, so escalate through the health model rather than giving up:
            // a minimised window or a flyout left open by an interrupted run both present
            // here, and both are repairable without disturbing the user.
            _ = try TeamsWindowsHealth.ensureHealthy()
            let retry = tw_open()
            guard retry == TW_OK else {
                throw TeamsWindowsError(code: retry, stage: "opening the Teams accessibility tree")
            }
            return
        }
        // Open succeeded, but a minimised window still reads as healthy while Chromium
        // treats it as occluded and discards every interaction. Repair that before acting.
        if TeamsWindowsHealth.current() == .minimized {
            _ = try TeamsWindowsHealth.ensureHealthy()
            _ = tw_open()
        }
    }

    public func prepare() throws {
        try exclusive {
            try ensureOpen()
            // A flyout left open by an interrupted run collapses the exposed tree to just
            // that dialog, which looks exactly like a dead tree until it is dismissed. The
            // macOS implementation hit this too.
            _ = try? closeOurSurfaces()
        }
    }

    public func availability() -> TargetAvailability {
        _ = tw_open()
        switch TeamsWindowsHealth.current() {
        case .healthy: return .ready
        case .notRunning: return .appNotRunning
        case .noWindow, .minimized, .treeUnavailable:
            let health = TeamsWindowsHealth.current()
            // Repairable states are reported as recoverable rather than as failures: the
            // coordinator retries those instead of standing down.
            return health.isRepairable ? .needsRecovery(health.explanation) : .appNotRunning
        }
    }

    // MARK: - Reading

    public func readCurrentStatus() throws -> String? {
        try exclusive {
            try ensureOpen()
            defer { _ = try? closeOurSurfaces() }

            let snapshot = try openFlyout()

            // Teams shows the readout only when a status message exists. Its absence
            // alongside the "set status message" entry means the status is genuinely
            // empty, which is a value, not a failure.
            guard let readout = snapshot.first(TeamsSelectors.statusReadout) else {
                if snapshot.contains(TeamsSelectors.setStatusItem) { return nil }
                throw PresenceTargetError.elementNotFound(
                    selector: TeamsSelectors.statusReadout.name, stage: "reading the current status")
            }
            return Self.statusText(from: readout)
        }
    }

    /// The readout as Teams renders it for a screen reader, e.g.
    /// `"Your current status message: ♪ Dreams by Fleetwood Mac . This will be displayed until 8:27 AM"`.
    /// Only the middle is the user's text.
    static func statusText(from element: UIAElement) -> String? {
        guard var text = element.value ?? element.axDescription else { return nil }

        let prefix = "Your current status message:"
        if let range = text.range(of: prefix, options: [.caseInsensitive, .anchored]) {
            text = String(text[range.upperBound...])
        }
        // The clear-duration suffix is a separate sentence Teams appends only when a
        // duration is set. Cutting at the marker rather than at the last period keeps
        // status messages that themselves contain a period intact.
        for marker in ["This will be displayed until", "Display until"] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                text = String(text[..<range.lowerBound])
                // Drop the separator Teams puts between the two sentences.
                while let last = text.last, last == "." || last == " " { text.removeLast() }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Writing

    public func apply(status: String) throws {
        try exclusive {
            try ensureOpen()
            defer { _ = try? closeOurSurfaces() }

            try openFlyout()
            try openEditor()
            try replaceComposeText(with: status)

            let snapshot = try UIASnapshot.capture()
            guard let done = snapshot.first(TeamsSelectors.doneButton),
                  let name = done.title ?? done.axDescription else {
                throw PresenceTargetError.elementNotFound(
                    selector: TeamsSelectors.doneButton.name, stage: "committing the status")
            }
            try press(named: name, control: TeamsSelectors.doneButton.name)

            // Verified against Teams' own readout, not against the compose box we typed
            // into. Anything less would report success for a status the editor accepted
            // and then discarded.
            let committed = waitForSnapshot { snap in
                guard let readout = snap.first(TeamsSelectors.statusReadout) else { return false }
                return Self.statusText(from: readout) == status
            }
            guard committed != nil else {
                let actual = (try? UIASnapshot.capture())
                    .flatMap { $0.first(TeamsSelectors.statusReadout) }
                    .flatMap { Self.statusText(from: $0) }
                throw PresenceTargetError.verificationFailed(expected: status, actual: actual ?? "")
            }
        }
    }

    public func clearStatus() throws {
        try exclusive {
            try ensureOpen()
            defer { _ = try? closeOurSurfaces() }

            let snapshot = try openFlyout()

            // Already empty: Teams offers "set status message" instead of the readout.
            guard let delete = snapshot.first(TeamsSelectors.deleteStatusButton),
                  let name = delete.axDescription ?? delete.title else {
                if snapshot.contains(TeamsSelectors.setStatusItem) { return }
                throw PresenceTargetError.elementNotFound(
                    selector: TeamsSelectors.deleteStatusButton.name, stage: "clearing the status")
            }
            try press(named: name, control: TeamsSelectors.deleteStatusButton.name)

            guard waitForSnapshot(where: { !$0.contains(TeamsSelectors.statusReadout) }) != nil else {
                throw PresenceTargetError.activationFailed(control: TeamsSelectors.deleteStatusButton.name)
            }
        }
    }

    /// Empties the compose box and types `text`, verifying both halves by reading Teams
    /// back rather than trusting either operation to have landed.
    private func replaceComposeText(with text: String) throws {
        // Cleared in rounds, re-reading what is left each time rather than trusting one
        // pass. The number of backspaces a contenteditable needs is not simply its
        // character count — an emoji or a combining sequence can take more than one, and a
        // single under-shooting pass leaves text behind that the new text is then appended
        // to. Observed in practice as a write failing with the *previous* track still in
        // the field.
        for attempt in 0..<3 {
            let existing = try composeText() ?? ""
            if existing.isEmpty { break }

            _ = tw_clear_field(Int32(existing.count + 8))
            if waitForSnapshot(timeout: 3.0, where: {
                (Self.composeContent(in: $0) ?? "x").isEmpty
            }) != nil { break }

            guard attempt < 2 else {
                throw PresenceTargetError.verificationFailed(
                    expected: "", actual: (try? composeText()) ?? "<unreadable>")
            }
        }

        typeIntoCompose(text)

        guard waitForSnapshot(timeout: 4.0, where: {
            Self.composeContent(in: $0) == text
        }) != nil else {
            throw PresenceTargetError.verificationFailed(
                expected: text, actual: (try? composeText()) ?? "<unreadable>")
        }
    }

    // MARK: - Diagnostics

    /// Resolves every selector that should be reachable with the profile flyout open, and
    /// reports which ones are not.
    ///
    /// The counterpart of `TeamsSelfTest`: when a Teams update moves the UI, this names the
    /// exact selector that stopped resolving rather than leaving a caller to guess from a
    /// generic "control not found".
    public func selectorReport() throws -> [(name: String, resolved: Bool, detail: String?)] {
        try exclusive {
            try ensureOpen()
            defer { _ = try? closeOurSurfaces() }

            let snapshot = try openFlyout()
            let expected: [AXSelector] = [
                TeamsSelectors.profileDialog,
                TeamsSelectors.statusReadout,
                TeamsSelectors.editStatusButton,
                TeamsSelectors.deleteStatusButton,
                TeamsSelectors.setStatusItem,
            ]
            return expected.map { selector in
                let hit = snapshot.first(selector)
                return (selector.name, hit != nil, hit?.axDescription ?? hit?.title)
            }
        }
    }

    /// Tries each text-entry method against the real compose box and reports what actually
    /// landed, **without pressing Done** — so nothing reaches the user's account.
    ///
    /// Exists because there is no way to know from a return code which method works: the
    /// compose box is a CKEditor contenteditable, and Chromium will accept a ValuePattern
    /// write that the editor's own model never sees.
    public func probeTextEntry(_ text: String) throws -> [(method: String, readBack: String?)] {
        try exclusive {
            try ensureOpen()
            defer { _ = try? closeOurSurfaces() }

            try openFlyout()
            try openEditor()

            var results: [(String, String?)] = []
            results.append(("baseline (before any write)", try composeText()))

            _ = setComposeValue(text)
            Thread.sleep(forTimeInterval: 0.6)
            results.append(("ValuePattern.SetValue", try composeText()))

            try replaceComposeText(with: text)
            results.append(("clear + WM_CHAR", try composeText()))

            return results
        }
    }

    /// Every element in one snapshot, for eyeballing what Teams is exposing right now.
    public func snapshotSummary() throws -> [(role: String, name: String, domID: String)] {
        try ensureOpen()
        return try UIASnapshot.capture().elements.map {
            ($0.role ?? "-", $0.axDescription ?? "", $0.domIdentifier ?? "")
        }
    }

    // MARK: - Driving the flyout

    /// Opens the profile flyout and returns a snapshot taken with it open.
    ///
    /// While the flyout is open Chromium exposes only its subtree, so the avatar button
    /// disappears from the tree — the flyout being open is therefore indistinguishable
    /// from a dead tree unless you look for the dialog first.
    @discardableResult
    private func openFlyout() throws -> UIASnapshot {
        var snapshot = try UIASnapshot.capture()
        if snapshot.contains(TeamsSelectors.profileDialog) { return snapshot }

        guard let avatar = snapshot.first(TeamsSelectors.profileButton),
              let name = avatar.axDescription else {
            throw PresenceTargetError.elementNotFound(
                selector: TeamsSelectors.profileButton.name, stage: "opening the profile flyout")
        }

        try press(named: name, control: TeamsSelectors.profileButton.name)

        guard let opened = waitForSnapshot(where: { $0.contains(TeamsSelectors.profileDialog) }) else {
            throw PresenceTargetError.activationFailed(control: TeamsSelectors.profileButton.name)
        }
        snapshot = opened
        return snapshot
    }

    /// Dismisses anything this app opened.
    ///
    /// Deliberately conditional: Escape is only ours to send when one of *our* surfaces is
    /// on screen. Every selector in `ourStatusSurfaces` is specific to the status UI, so
    /// this can never dismiss a sign-in sheet or a call window the user cares about.
    @discardableResult
    private func closeOurSurfaces() throws -> Bool {
        var snapshot = try UIASnapshot.capture()
        var attempts = 0

        while TeamsSelectors.ourStatusSurfaces.contains(where: { snapshot.contains($0) }) {
            guard attempts < 3 else { return false }
            attempts += 1
            _ = tw_post_key(Int32(TW_VK_ESCAPE))
            guard let settled = waitForSnapshot(timeout: 1.5, where: { snap in
                !TeamsSelectors.ourStatusSurfaces.contains(where: { snap.contains($0) })
            }) else {
                snapshot = try UIASnapshot.capture()
                continue
            }
            snapshot = settled
        }
        return true
    }

    /// Opens the status editor from an already-open flyout.
    ///
    /// Teams shows `editStatusButton` when a status message exists and `setStatusItem`
    /// when none does, so both are tried.
    @discardableResult
    private func openEditor() throws -> UIASnapshot {
        let snapshot = try UIASnapshot.capture()
        if snapshot.contains(TeamsSelectors.composeBox) { return snapshot }

        let entry = snapshot.first(TeamsSelectors.editStatusButton)
            ?? snapshot.first(TeamsSelectors.setStatusItem)
        guard let entry, let name = entry.axDescription ?? entry.title else {
            throw PresenceTargetError.elementNotFound(
                selector: "editStatusButton or setStatusItem", stage: "opening the status editor")
        }

        try press(named: name, control: TeamsSelectors.editStatusButton.name)

        guard let opened = waitForSnapshot(where: { $0.contains(TeamsSelectors.composeBox) }) else {
            throw PresenceTargetError.activationFailed(control: TeamsSelectors.editStatusButton.name)
        }
        return opened
    }

    /// What the compose box currently holds, read back from Teams rather than remembered.
    private func composeText() throws -> String? {
        Self.composeContent(in: try UIASnapshot.capture())
    }

    /// The user-visible content of the compose box.
    ///
    /// CKEditor renders its placeholder as real text *inside* the contenteditable, so an
    /// empty box reports "Type @ to mention someone in your status" as its accessible
    /// value. Taken at face value, an emptied field looks like a full one and clearing can
    /// never be verified — so a value equal to the placeholder is reported as empty.
    static func composeContent(of element: UIAElement) -> String {
        let raw = (element.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = (element.placeholder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !placeholder.isEmpty, raw == placeholder { return "" }
        return raw
    }

    /// The compose box's content within a snapshot, or nil if the box is not present.
    private static func composeContent(in snapshot: UIASnapshot) -> String? {
        guard let box = snapshot.first(TeamsSelectors.composeBox) else { return nil }
        return composeContent(of: box)
    }

    private func setComposeValue(_ text: String) -> Bool {
        var id = Array("status-note-compose".utf16); id.append(0)
        var payload = Array(text.utf16); payload.append(0)
        return id.withUnsafeBufferPointer { idBuf in
            payload.withUnsafeBufferPointer { textBuf in
                tw_set_value(idBuf.baseAddress, textBuf.baseAddress) == TW_OK
            }
        }
    }

    private func typeIntoCompose(_ text: String) {
        var payload = Array(text.utf16); payload.append(0)
        _ = payload.withUnsafeBufferPointer { tw_type_text($0.baseAddress) }
    }

    /// Presses a control by its accessible name, through MSAA.
    ///
    /// The delivery says nothing about whether Teams acted; callers verify separately.
    private func press(named name: String, control: String) throws {
        var utf16 = Array(name.utf16)
        utf16.append(0)
        let status = utf16.withUnsafeBufferPointer { tw_msaa_press($0.baseAddress) }
        guard status == TW_OK else {
            throw PresenceTargetError.elementNotFound(selector: control, stage: "pressing \(control)")
        }
    }

    /// Re-reads the tree until `predicate` holds, or the timeout elapses.
    private func waitForSnapshot(timeout: TimeInterval? = nil,
                                 where predicate: (UIASnapshot) -> Bool) -> UIASnapshot? {
        AXPoll.waitForValue(timeout: timeout ?? settleTimeout, interval: 0.12) {
            guard let snapshot = try? UIASnapshot.capture() else { return nil }
            return predicate(snapshot) ? snapshot : nil
        }
    }
}
