import Foundation

/// Reads the currently-playing track from the Spotify Web API.
///
/// The default source: it sees playback on any device signed in to the account, not just
/// this Mac.
public final class SpotifyWebAPISource: PresenceSource {

    public let kind: PresenceSourceKind = .spotifyWebAPI
    public var displayName: String { kind.displayName }
    public let requiresAuthorization = true

    private static let currentlyPlayingURL =
        URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!

    public let auth: SpotifyAuth
    private let session: URLSession

    /// Set when Spotify returns 429; the coordinator honours it before polling again.
    public private(set) var rateLimitedUntil: Date?

    public init(auth: SpotifyAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    public var isAuthorized: Bool { auth.isAuthorized }

    public func fetch() async throws -> TrackPresence? {
        if let rateLimitedUntil, Date() < rateLimitedUntil {
            throw PresenceSourceError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSinceNow)
        }

        let token = try await auth.validAccessToken()
        do {
            return try await request(with: token)
        } catch let error as PresenceSourceError {
            // A 401 is ambiguous on this API — see `classify`. Only the genuinely
            // token-shaped kind is worth a refresh, and only once: refreshing on a scope
            // problem loops forever.
            guard case .authorizationExpired = error else { throw error }
            let refreshed = try await auth.refresh()
            return try await request(with: refreshed.accessToken)
        }
    }

    private func request(with token: String) async throws -> TrackPresence? {
        var request = URLRequest(url: Self.currentlyPlayingURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }
            throw PresenceSourceError.network(urlError.localizedDescription)
        } catch {
            throw PresenceSourceError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PresenceSourceError.network("malformed response")
        }

        switch http.statusCode {
        case 200:
            rateLimitedUntil = nil
            return Self.parse(data)
        case 204:
            // Documented as 200 + is_playing:false, but the live API really sends 204.
            // This is a normal "nothing is playing" state, not an error.
            rateLimitedUntil = nil
            return nil
        case 429:
            let retryAfter = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            Log.spotify.warning("rate limited by Spotify; backing off \(Int(retryAfter), privacy: .public)s")
            throw PresenceSourceError.rateLimited(retryAfter: retryAfter)
        default:
            throw Self.classify(status: http.statusCode, body: data)
        }
    }

    /// Turn an HTTP failure into something the coordinator can act on.
    ///
    /// The subtle case, found in Phase 0: **Spotify answers an insufficient-scope request
    /// with `401 "Permissions missing"`, not `403`.** A naive "401 means expired, refresh
    /// and retry" loop therefore spins forever against a grant that can never be repaired
    /// by refreshing. The message body is what separates the two.
    static func classify(status: Int, body: Data) -> PresenceSourceError {
        let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: body))?.error.message

        if status == 401 {
            if let message, message.localizedCaseInsensitiveContains("permission") {
                return .permissionsMissing(message)
            }
            return .authorizationExpired
        }
        if status == 403 {
            return .permissionsMissing(message ?? "forbidden")
        }
        return .serviceError(status: status, message: message)
    }

    static func parse(_ data: Data) -> TrackPresence? {
        guard let body = try? JSONDecoder().decode(CurrentlyPlayingBody.self, from: data),
              let item = body.item else { return nil }
        // Podcasts and adverts have no meaningful artist; treat them as no-presence
        // rather than publishing something misleading.
        guard body.currently_playing_type == nil || body.currently_playing_type == "track" else {
            return nil
        }
        return TrackPresence(
            trackName: item.name,
            artists: item.artists?.map(\.name) ?? [],
            albumName: item.album?.name,
            isPlaying: body.is_playing ?? false,
            trackID: item.id
        )
    }

    // MARK: - Wire format

    private struct CurrentlyPlayingBody: Decodable {
        let is_playing: Bool?
        let currently_playing_type: String?
        let item: Item?

        struct Item: Decodable {
            let id: String?
            let name: String
            let artists: [Artist]?
            let album: Album?
        }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let name: String }
    }

    private struct APIErrorEnvelope: Decodable {
        struct Body: Decodable {
            let status: Int?
            let message: String?
        }
        let error: Body
    }
}
