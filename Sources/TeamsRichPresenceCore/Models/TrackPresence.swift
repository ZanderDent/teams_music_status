import Foundation

/// What a music source reports about the current track.
///
/// Deliberately narrow: this is the contract every `PresenceSource` must satisfy, and it
/// has to be expressible by both the Spotify Web API and the local AppleScript interface
/// (which, for example, only knows the primary artist).
public struct TrackPresence: Equatable, Sendable {
    public let trackName: String
    public let artists: [String]
    public let albumName: String?
    public let isPlaying: Bool
    /// Stable identity for change detection. Nil sources fall back to comparing rendered text.
    public let trackID: String?

    public init(trackName: String,
                artists: [String],
                albumName: String? = nil,
                isPlaying: Bool,
                trackID: String? = nil) {
        self.trackName = trackName
        self.artists = artists
        self.albumName = albumName
        self.isPlaying = isPlaying
        self.trackID = trackID
    }

    public var primaryArtist: String { artists.first ?? "" }
    public var joinedArtists: String { artists.joined(separator: ", ") }

    /// Identity used by the coordinator to decide "is this a different track?".
    public var identity: String {
        trackID ?? "\(trackName)\u{1}\(joinedArtists)"
    }
}

/// Which source is feeding presence.
public enum PresenceSourceKind: String, CaseIterable, Codable, Sendable {
    case spotifyWebAPI
    case spotifyLocal

    public var displayName: String {
        switch self {
        case .spotifyWebAPI: return "Spotify Web API"
        case .spotifyLocal: return "Local Spotify app"
        }
    }

    public var summary: String {
        switch self {
        case .spotifyWebAPI:
            return "Sees playback on any device signed in to your account. Requires a one-time Spotify sign-in."
        case .spotifyLocal:
            return "Reads the Spotify app on this Mac only. No sign-in, works offline, shows the primary artist only."
        }
    }
}
