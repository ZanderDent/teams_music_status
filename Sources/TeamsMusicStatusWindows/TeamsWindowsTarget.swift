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

    // MARK: - Lifecycle

    /// Opens (or re-opens) Chromium's web content tree.
    ///
    /// Not idempotent-and-cheap by accident: Chromium lets the tree lapse when no client is
    /// reading, so this is called before every operation rather than once at startup.
    private func ensureOpen() throws {
        let status = tw_open()
        guard status == TW_OK else { throw TeamsWindowsError(code: status, stage: "opening the Teams accessibility tree") }
    }

    public func prepare() throws {
        try TeamsUI.exclusive {
            try ensureOpen()
            // A flyout left open by an interrupted run collapses the exposed tree to just
            // that dialog, which looks exactly like a dead tree until it is dismissed. The
            // macOS implementation hit this too.
            _ = try? closeOurSurfaces()
        }
    }

    public func availability() -> TargetAvailability {
        let status = tw_open()
        switch status {
        case TW_OK: return .ready
        case TW_ERR_NO_TEAMS: return .appNotRunning
        case TW_ERR_TREE_UNAVAIL: return .needsRecovery("Teams has not published its accessibility tree.")
        default: return .needsRecovery("Windows accessibility error \(status).")
        }
    }

    // MARK: - Reading

    public func readCurrentStatus() throws -> String? {
        try TeamsUI.exclusive {
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
        throw PresenceTargetError.notReady(.needsRecovery("Writing is not implemented yet on Windows."))
    }

    public func clearStatus() throws {
        throw PresenceTargetError.notReady(.needsRecovery("Clearing is not implemented yet on Windows."))
    }

    // MARK: - Diagnostics

    /// Resolves every selector that should be reachable with the profile flyout open, and
    /// reports which ones are not.
    ///
    /// The counterpart of `TeamsSelfTest`: when a Teams update moves the UI, this names the
    /// exact selector that stopped resolving rather than leaving a caller to guess from a
    /// generic "control not found".
    public func selectorReport() throws -> [(name: String, resolved: Bool, detail: String?)] {
        try TeamsUI.exclusive {
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
