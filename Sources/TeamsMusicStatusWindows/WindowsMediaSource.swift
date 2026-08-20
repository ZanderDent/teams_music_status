import CTeamsWin
import Foundation
import TeamsMusicStatusCore

/// Presence from the Windows system media session.
///
/// The counterpart of the macOS `SpotifyLocalSource`, and the same trade: it sees only
/// what is playing on *this machine*, needs no sign-in, and works offline. Two differences
/// are worth knowing:
///
/// * It reports the album and every artist, where the macOS Apple Events interface only
///   exposes the primary artist. `{album}` and `{artists}` therefore render fully here.
/// * There is no permission grant to fail. macOS gates Apple Events behind a user prompt
///   that can be refused; Windows exposes the media session to any process, so
///   `automationPermissionDenied` has no Windows equivalent and is never thrown.
///
/// It has no notion of a Spotify track id, so `TrackPresence.identity` falls back to
/// comparing title and artists — which is exactly what the model already does when
/// `trackID` is nil.
public final class WindowsMediaSource: PresenceSource, @unchecked Sendable {

    /// Substring matched against the media session's source application id, e.g.
    /// `SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify`. Nil follows whichever player
    /// Windows considers current.
    private let appIdNeedle: String?

    public init(appIdNeedle: String? = "Spotify") {
        self.appIdNeedle = appIdNeedle
    }

    public var kind: PresenceSourceKind { .spotifyLocal }
    public var displayName: String { "Windows media session" }

    /// Nothing to authorise: unlike Apple Events, the media session is readable by any
    /// process without a prompt.
    public var requiresAuthorization: Bool { false }
    public var isAuthorized: Bool { true }

    public func fetch() async throws -> TrackPresence? {
        try read()
    }

    /// Synchronous read, exposed for the diagnostics CLI and for tests that want to drive
    /// the source without an async context.
    public func read() throws -> TrackPresence? {
        var raw = TWNowPlaying()
        let status: Int32 = withUnsafeMutablePointer(to: &raw) { out in
            guard let needle = appIdNeedle else { return tw_now_playing(out) }
            return Array(needle.utf16).withUnsafeBufferPointer { buf in
                // The shim reads a NUL-terminated string; String.utf16 is not terminated.
                var terminated = Array(buf)
                terminated.append(0)
                return terminated.withUnsafeBufferPointer { tw_now_playing_for($0.baseAddress, out) }
            }
        }

        switch status {
        case TW_OK:
            break
        case TW_ERR_NO_SESSION:
            // Nothing is playing. A normal state, not an error — the same contract the
            // macOS sources honour.
            return nil
        default:
            throw PresenceSourceError.serviceError(
                status: Int(status), message: "The Windows media session could not be read.")
        }

        let title = Self.string(from: &raw.title)
        guard !title.isEmpty else {
            // A session that reports no title is not a track. Treat it as silence rather
            // than publishing an empty status.
            return nil
        }

        return TrackPresence(
            trackName: title,
            artists: Self.artists(from: Self.string(from: &raw.artist)),
            albumName: Self.emptyAsNil(Self.string(from: &raw.album)),
            isPlaying: raw.isPlaying == 1,
            trackID: nil
        )
    }

    /// The source application id of the session that was read, for diagnostics.
    public func currentAppID() -> String? {
        var raw = TWNowPlaying()
        let status = withUnsafeMutablePointer(to: &raw) { tw_now_playing($0) }
        guard status == TW_OK else { return nil }
        return Self.emptyAsNil(Self.string(from: &raw.appId))
    }

    // MARK: - Marshalling

    /// Reads a fixed-size, NUL-terminated UTF-16 buffer out of the C struct.
    private static func string<T>(from buffer: inout T) -> String {
        withUnsafeBytes(of: &buffer) { raw in
            let units = raw.bindMemory(to: UInt16.self)
            let end = units.firstIndex(of: 0) ?? units.count
            return String(decoding: units[..<end], as: UTF16.self)
        }
    }

    private static func emptyAsNil(_ s: String) -> String? { s.isEmpty ? nil : s }

    /// Spotify publishes collaborating artists as one comma-separated string. Splitting it
    /// is what makes `{artists}` render as "A, B" and `{artist}` as just "A", matching the
    /// Web API source. Only ", " is treated as a separator: a bare comma appears inside
    /// real artist names, and splitting on it would mangle them.
    private static func artists(from joined: String) -> [String] {
        guard !joined.isEmpty else { return [] }
        return joined
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
