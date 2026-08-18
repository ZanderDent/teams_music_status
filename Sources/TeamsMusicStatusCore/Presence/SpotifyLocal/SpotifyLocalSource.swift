import AppKit
import Foundation

/// What one reading of the local Spotify app actually said.
///
/// The point of this type is that **silence and failure are different answers**. The
/// source previously returned `TrackPresence?`, so "Spotify is stopped", "Spotify is not
/// running", "the Apple Event failed" and "the answer did not parse" all arrived as `nil`.
/// The coordinator reads `nil` as "nothing is playing", starts the pause grace, and can
/// end up restoring the user's previous Teams status over a track that never stopped.
public enum LocalPlaybackReading: Equatable, Sendable {
    /// The Spotify app is not running. Not an error, and not something to fix.
    case notRunning
    /// Running, with the player stopped. Genuine silence.
    case stopped
    /// Paused, with whatever metadata Spotify still exposes for the loaded track.
    case paused(TrackPresence)
    case playing(TrackPresence)

    /// The presence to publish, if any. Paused and playing both carry a track; the
    /// `isPlaying` flag on `TrackPresence` distinguishes them downstream.
    public var presence: TrackPresence? {
        switch self {
        case .playing(let t), .paused(let t): return t
        case .notRunning, .stopped: return nil
        }
    }

    /// Whether this reading is evidence that nothing is playing, as opposed to evidence
    /// that we could not tell. Only these two states justify winding down a status.
    public var isDefinitelySilent: Bool {
        switch self {
        case .notRunning, .stopped: return true
        case .paused, .playing: return false
        }
    }
}

/// Reads playback from the Spotify desktop app via its AppleScript dictionary.
///
/// No OAuth, no network, no rate limits, no Spotify developer app, and no five-user
/// allowlist — which is what makes it the only path that works for an arbitrary member of
/// the public. The trade-offs, all surfaced in the UI:
///
/// * It only sees the Spotify app **on this Mac**. Phone, web player and other computers
///   are invisible.
/// * It reports only the **primary artist**. Measured against the Web API in Phase 0:
///   `Dom Dolla` here versus `Dom Dolla, Go Freek` there, for the same track id.
/// * It needs the Automation (Apple Events) permission, prompted on first use — so it is
///   only ever touched once the user has actually selected this source.
/// * It depends on Spotify continuing to ship its scripting dictionary.
/// One-shot ownership, so exactly one of "the read finished" and "the deadline passed"
/// resumes the continuation. Resuming a checked continuation twice is a hard crash.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    /// True for the first caller only.
    func takeOwnership() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

public final class SpotifyLocalSource: PresenceSource {

    public let kind: PresenceSourceKind = .spotifyLocal
    public var displayName: String { kind.displayName }
    /// Not an OAuth authorization, but macOS Automation consent is a gate of the same shape.
    public let requiresAuthorization = false

    public static let bundleIdentifier = "com.spotify.client"

    /// How long one read may take before it is called a timeout rather than waited on.
    ///
    /// A hung Apple Event once blocked a caller for over forty seconds. Generous enough
    /// that a busy Spotify still answers — measured reads complete in tens of
    /// milliseconds — and short enough that a poll loop is never wedged by one.
    public static let readTimeout: TimeInterval = 5

    /// One round trip returns everything; querying properties one at a time is far slower
    /// and can also tear — state read before a track change, metadata read after it.
    ///
    /// Three things learned the hard way:
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
        return pstate & d & (name of trk) & d & (artist of trk) & d & (album of trk) & d & (id of trk) & d & ((duration of trk) as text) & d & ((player position) as text)
    end tell
    """

    public init() {}

    /// True when the Spotify app is installed. Automation consent is checked lazily,
    /// because probing it triggers the very prompt we want to defer.
    public var isAuthorized: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) != nil
    }

    /// Checked without Apple Events, so it cannot launch Spotify or trigger a prompt.
    public var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    // MARK: - Reading

    /// The full reading, with failures as failures and a bounded wait.
    ///
    /// Spotify occasionally does not answer an Apple Event at all. Measured here: roughly
    /// one read in a hundred hangs, once for over forty seconds. `NSAppleScript` has no
    /// timeout of its own, so without this a single hang stalls the caller indefinitely —
    /// and the old code eventually surfaced that as `nil`, i.e. "nothing is playing".
    ///
    /// The blocked thread cannot be reclaimed (there is no way to cancel an in-flight
    /// Apple Event), so it is left to finish and its result discarded. What this bounds is
    /// how long the *caller* waits, which is what the poll loop needs.
    public func read() async throws -> LocalPlaybackReading {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = ManagedAtomicFlag()
            let deadline = DispatchTime.now() + Self.readTimeout

            // NSAppleScript is not thread-safe and blocks; keep it off the caller's actor.
            DispatchQueue.global(qos: .utility).async {
                do {
                    let reading = try Self.readSynchronously()
                    if resumed.takeOwnership() { continuation.resume(returning: reading) }
                } catch {
                    if resumed.takeOwnership() { continuation.resume(throwing: error) }
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                if resumed.takeOwnership() {
                    Log.spotify.error("local Spotify read exceeded \(Self.readTimeout, privacy: .public)s")
                    continuation.resume(throwing: PresenceSourceError.timedOut(seconds: Self.readTimeout))
                }
            }
        }
    }

    /// `PresenceSource` conformance. Note the asymmetry this type exists to fix: `nil`
    /// here means *observed silence only*. Every failure throws.
    public func fetch() async throws -> TrackPresence? {
        try await read().presence
    }

    static func readSynchronously() throws -> LocalPlaybackReading {
        // Cheapest possible answer, and the only one that cannot launch Spotify.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            return .notRunning
        }
        guard let script = NSAppleScript(source: Self.script) else {
            throw PresenceSourceError.parseFailure("the Spotify script would not compile")
        }

        var errorInfo: NSDictionary?
        let started = Date()
        let result = script.executeAndReturnError(&errorInfo)
        let elapsed = Date().timeIntervalSince(started)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown"
            switch code {
            case -1743:
                // The user declined, or has never granted, the Automation prompt.
                throw PresenceSourceError.automationPermissionDenied
            case -600, -609:
                // Spotify quit between the running check and the event.
                return .notRunning
            case -1712:
                throw PresenceSourceError.timedOut(seconds: elapsed)
            default:
                Log.spotify.error("local source Apple Event \(code, privacy: .public): \(message, privacy: .public)")
                throw PresenceSourceError.appleEventFailure(code: code, message: message)
            }
        }

        // NSAppleScript reports no error but hands back a descriptor with no string when
        // the event is dropped. That used to become `nil`, i.e. "nothing is playing".
        guard let raw = result.stringValue else {
            throw PresenceSourceError.appleEventFailure(
                code: Int(result.descriptorType),
                message: "Spotify returned no readable value")
        }
        return try parse(raw)
    }

    // MARK: - Parsing

    static func parse(_ raw: String) throws -> LocalPlaybackReading {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "NOTRUNNING" { return .notRunning }
        if trimmed == "STOPPED" { return .stopped }
        guard !trimmed.isEmpty else { throw PresenceSourceError.parseFailure("empty answer") }

        let fields = trimmed.components(separatedBy: "\t")
        // state, name, artist, album, id — duration and position are newer and optional so
        // an older Spotify still parses rather than failing outright.
        guard fields.count >= 5 else {
            throw PresenceSourceError.parseFailure("expected at least 5 fields, got \(fields.count)")
        }

        let state = fields[0]
        guard state == "playing" || state == "paused" else {
            throw PresenceSourceError.parseFailure("unknown player state '\(state)'")
        }

        let presence = TrackPresence(
            trackName: fields[1],
            artists: fields[2].isEmpty ? [] : [fields[2]],
            albumName: fields[3].isEmpty ? nil : fields[3],
            isPlaying: state == "playing",
            trackID: fields[4].split(separator: ":").last.map(String.init)
        )
        return state == "playing" ? .playing(presence) : .paused(presence)
    }
}
