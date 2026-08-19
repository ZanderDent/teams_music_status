import AppKit
import CoreServices
import Foundation

/// The macOS Automation (Apple Events) consent state for a target application.
///
/// This exists because "we could not read Spotify" is four different problems wearing the
/// same coat, and only one of them is the user's to fix. Collapsing them is what produced
/// the v1.0.0 blocker: onboarding said "Spotify is not connected" whether the app was
/// missing, closed, un-prompted or actively blocked, and the one state that needed a
/// button — `denied` — looked identical to the one that needed nothing but a retry.
public enum AutomationPermission: Equatable, Sendable {
    /// macOS has never asked. Sending a real Apple Event is what makes it ask.
    case notDetermined
    /// The user pressed Don't Allow, or switched the app off in System Settings. macOS
    /// will NOT prompt again on its own — this is the state that needs a recovery route.
    case denied
    case granted
    /// The target is not running, so consent cannot be evaluated. Not a permission problem.
    case targetNotRunning
    /// Anything else, carried verbatim rather than guessed at.
    case unknown(OSStatus)

    public var isUsable: Bool { self == .granted }
}

/// Reads the Automation consent state without guessing, and — when asked — provokes the
/// system prompt.
public enum SpotifyAutomation {

    /// `AEDeterminePermissionToAutomateTarget` is the only API that distinguishes
    /// "never asked" (-1744) from "refused" (-1743). `NSAppleScript` reports both as
    /// -1743, which is why the app could not tell a fresh user from a blocked one.
    ///
    /// - Parameter promptIfNeeded: when true and the state is `notDetermined`, macOS
    ///   displays the "wants to control Spotify" dialog and this call **blocks** until the
    ///   user answers. Never pass true on the main thread.
    public static func permission(
        for bundleIdentifier: String = SpotifyLocalSource.bundleIdentifier,
        promptIfNeeded: Bool = false
    ) -> AutomationPermission {
        var target = AEDesc()
        let identifier = Array(bundleIdentifier.utf8)
        let createStatus = identifier.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target)
        }
        guard createStatus == noErr else { return .unknown(OSStatus(createStatus)) }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            promptIfNeeded
        )
        return classify(status)
    }

    /// Split out so the mapping is testable without a live TCC database.
    public static func classify(_ status: OSStatus) -> AutomationPermission {
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            return .unknown(status)
        }
    }

    /// Opens the exact System Settings pane that lists this app under Automation.
    ///
    /// The pane cannot be deep-linked to a single app, so the user still has to find the
    /// "Teams Music Status" row — but landing them on the right pane is the difference
    /// between a 5-second fix and a support request.
    @MainActor
    public static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
