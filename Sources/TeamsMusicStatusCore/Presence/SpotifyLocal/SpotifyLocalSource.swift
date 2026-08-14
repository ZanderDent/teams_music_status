import AppKit
import Foundation

/// Reads playback from the Spotify desktop app via its AppleScript dictionary.
///
/// No OAuth, no network, no rate limits, and it works offline. The trade-offs, all of
/// which the UI surfaces to the user:
///
/// * It only sees the Spotify app **on this Mac**. Playback from a phone, the web player
///   or another computer is invisible.
/// * It reports only the **primary artist**. Measured side by side in Phase 0, this source
///   returned `Dom Dolla` where the Web API returned `Dom Dolla, Go Freek` for the same
///   track id.
/// * It needs the Automation (Apple Events) permission, which macOS prompts for the first
///   time it is used — so we only ever touch it when the user has actually selected this
///   source.
/// * It depends on Spotify continuing to ship its scripting dictionary.
public final class SpotifyLocalSource: PresenceSource {

    public let kind: PresenceSourceKind = .spotifyLocal
    public var displayName: String { kind.displayName }
    /// Not an OAuth authorization, but macOS Automation consent is a gate of the same shape.
    public let requiresAuthorization = false

    public static let bundleIdentifier = "com.spotify.client"

    /// One round trip returns everything; querying properties one at a time is far slower.
    ///
    /// Two things learned the hard way:
    ///  * `st` and `t` are reserved tokens in AppleScript and fail to parse — hence
    ///    `pstate` / `trk`.
    ///  * The `is running` test is OUTSIDE the `tell` block on purpose: addressing a
    ///    non-running app inside `tell` would *launch Spotify* as a side effect of a
    ///    read, which a background poller must never do.
    ///  * `duration` is milliseconds despite the dictionary documenting seconds.
    private static let script = """
    if application id "\(bundleIdentifier)" is not running then return "NOTRUNNING"
    tell application id "\(bundleIdentifier)"
        set pstate to player state as text
        if pstate is "stopped" then return "STOPPED"
        set trk to current track
        set d to tab
        return pstate & d & (name of trk) & d & (artist of trk) & d & (album of trk) & d & (id of trk)
    end tell
    """

    public init() {}

    /// True when the Spotify app is installed. Automation consent is checked lazily,
    /// because probing it triggers the very prompt we want to defer.
    public var isAuthorized: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) != nil
    }

    public var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    public func fetch() async throws -> TrackPresence? {
        try await withCheckedThrowingContinuation { continuation in
            // NSAppleScript is not thread-safe and blocks; keep it off the caller's actor.
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try Self.readSynchronously()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func readSynchronously() throws -> TrackPresence? {
        guard let script = NSAppleScript(source: Self.script) else {
            throw PresenceSourceError.serviceError(status: -1, message: "could not compile the Spotify script")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown"
            // -1743: the user declined the Automation prompt. -600: app not running.
            if code == -1743 { throw PresenceSourceError.automationPermissionDenied }
            if code == -600 { throw PresenceSourceError.appNotRunning }
            Log.spotify.error("local source AppleScript error \(code, privacy: .public): \(message, privacy: .public)")
            throw PresenceSourceError.serviceError(status: code, message: message)
        }

        guard let raw = result.stringValue else { return nil }
        return parse(raw)
    }

    static func parse(_ raw: String) -> TrackPresence? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "NOTRUNNING", trimmed != "STOPPED", !trimmed.isEmpty else { return nil }

        let fields = trimmed.components(separatedBy: "\t")
        guard fields.count >= 5 else { return nil }
        let identifier = fields[4].split(separator: ":").last.map(String.init)

        return TrackPresence(
            trackName: fields[1],
            artists: fields[2].isEmpty ? [] : [fields[2]],
            albumName: fields[3].isEmpty ? nil : fields[3],
            isPlaying: fields[0] == "playing",
            trackID: identifier
        )
    }
}
