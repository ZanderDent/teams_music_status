import AppKit
import CryptoKit
import Foundation

/// OAuth 2.0 Authorization Code with PKCE for the Spotify Web API.
///
/// **No client secret, anywhere.** PKCE exists precisely so a distributed desktop app does
/// not need one, and a shipped secret would be trivially extractable regardless. The
/// client ID is public by design and safe to bundle.
///
/// Tokens live in the Keychain. Nothing in this file ever logs a token, an authorization
/// code, or the PKCE verifier — `Redact.secret` is the only permitted representation.
public final class SpotifyAuth {

    public struct Configuration: Sendable {
        public let clientID: String
        public let redirectURI: URL
        public let scopes: [String]

        /// `user-read-currently-playing` alone yields track, artists, `is_playing` and
        /// progress. `user-read-playback-state` is deliberately NOT requested: it grants
        /// strictly more than this product needs.
        public static let defaultScopes = ["user-read-currently-playing"]

        /// Spotify stopped accepting `localhost` as a redirect host (enforced 27 Nov 2025).
        /// A loopback IP literal over HTTP is still permitted and is what we register.
        public static let defaultRedirectURI = URL(string: "http://127.0.0.1:8888/callback")!

        public init(clientID: String,
                    redirectURI: URL = Configuration.defaultRedirectURI,
                    scopes: [String] = Configuration.defaultScopes) {
            self.clientID = clientID
            self.redirectURI = redirectURI
            self.scopes = scopes
        }
    }

    public struct Tokens: Codable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var scope: String

        public var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
    }

    public enum AuthError: LocalizedError, Equatable {
        case notConfigured
        case cancelled
        case timedOut
        case stateMismatch
        case denied(String)
        case tokenExchangeFailed(String)
        case portUnavailable(UInt16)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No Spotify client ID is configured. See docs/README for setup."
            case .cancelled:
                return "Spotify sign-in was cancelled."
            case .timedOut:
                return "Spotify sign-in timed out. Please try again."
            case .stateMismatch:
                return "Spotify sign-in failed a security check and was aborted."
            case .denied(let reason):
                return "Spotify sign-in was declined (\(reason))."
            case .tokenExchangeFailed(let detail):
                return "Spotify rejected the sign-in: \(detail)"
            case .portUnavailable(let port):
                return "Port \(port) is already in use, so the Spotify sign-in could not "
                     + "receive its response. Close whatever is using it and try again."
            }
        }
    }

    private static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    private static let keychainAccount = "spotify-oauth-tokens"

    private let configuration: Configuration
    private let keychain: KeychainStore
    private let session: URLSession
    private let lock = NSLock()
    private var cachedTokens: Tokens?

    public init(configuration: Configuration,
                keychain: KeychainStore = KeychainStore(service: "com.zanderdent.TeamsMusicStatus.spotify"),
                session: URLSession = .shared) {
        self.configuration = configuration
        self.keychain = keychain
        self.session = session
        // Deliberately NO Keychain access here.
        //
        // This initialiser runs inside SwiftUI's @StateObject construction, on the main
        // thread, during app launch. SecItemCopyMatching can block indefinitely on
        // securityd — for example when the item was written by a different code identity
        // and macOS wants to prompt. A menu-bar app has no window to show that prompt
        // over, so the app simply hangs at launch with no UI and no logs. Observed and
        // sampled during acceptance testing.
        //
        // Call `primeFromKeychain()` off the main thread instead.
    }

    /// Load stored tokens. **Never call this on the main thread** — see `init`.
    /// Idempotent and safe to call repeatedly.
    public func primeFromKeychain() {
        let loaded = try? keychain.value(Tokens.self, account: Self.keychainAccount)
        lock.lock()
        if cachedTokens == nil { cachedTokens = loaded }
        let authorized = cachedTokens != nil
        lock.unlock()
        Log.oauth.info("Keychain primed; Spotify \(authorized ? "connected" : "not connected", privacy: .public)")
    }

    // MARK: - State

    public var isAuthorized: Bool {
        lock.lock(); defer { lock.unlock() }
        return cachedTokens != nil
    }

    public var grantedScopes: [String] {
        lock.lock(); defer { lock.unlock() }
        return cachedTokens?.scope.split(separator: " ").map(String.init) ?? []
    }

    /// True when the stored grant is missing something we now ask for — a sign that the
    /// user needs to reconnect rather than that a refresh is due.
    public var hasAllRequiredScopes: Bool {
        let granted = Set(grantedScopes)
        return configuration.scopes.allSatisfy(granted.contains)
    }

    public func signOut() {
        lock.lock()
        cachedTokens = nil
        lock.unlock()
        try? keychain.delete(account: Self.keychainAccount)
        Log.oauth.info("Spotify tokens deleted from the Keychain")
    }

    private func store(_ tokens: Tokens) {
        lock.lock()
        cachedTokens = tokens
        lock.unlock()
        do { try keychain.setValue(tokens, account: Self.keychainAccount) }
        catch { Log.keychain.error("failed to persist Spotify tokens: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - PKCE

    static func makeVerifier() -> String {
        // 64 random bytes -> 86 base64url characters, inside the 43...128 range Spotify allows.
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorization flow

    /// Run the full browser sign-in. Returns when tokens are stored, or throws.
    ///
    /// The loopback listener is started *before* the browser opens and is always torn
    /// down, including on cancellation and timeout.
    public func authorize(timeout: TimeInterval = 180) async throws {
        guard !configuration.clientID.isEmpty else { throw AuthError.notConfigured }

        let verifier = Self.makeVerifier()
        let challenge = Self.challenge(for: verifier)
        let state = Self.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))

        let port = UInt16(configuration.redirectURI.port ?? 8888)
        let listener = LoopbackCallbackServer(port: port,
                                              path: configuration.redirectURI.path)
        do { try listener.start() }
        catch { throw AuthError.portUnavailable(port) }
        defer { listener.stop() }

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: configuration.clientID),
            .init(name: "scope", value: configuration.scopes.joined(separator: " ")),
            .init(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            .init(name: "state", value: state),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]

        Log.oauth.info("starting Spotify authorization (scopes: \(self.configuration.scopes.joined(separator: " "), privacy: .public))")
        NSWorkspace.shared.open(components.url!)

        let callback = try await listener.waitForCallback(timeout: timeout)

        if let error = callback["error"] {
            throw error == "access_denied" ? AuthError.cancelled : AuthError.denied(error)
        }
        guard callback["state"] == state else {
            Log.oauth.error("authorization state mismatch — possible CSRF, aborting")
            throw AuthError.stateMismatch
        }
        guard let code = callback["code"] else { throw AuthError.cancelled }

        let tokens = try await exchange(code: code, verifier: verifier)
        store(tokens)
        Log.oauth.info("Spotify authorized; access token \(Redact.secret(tokens.accessToken), privacy: .public), expires in \(Int(tokens.expiresAt.timeIntervalSinceNow), privacy: .public)s")
    }

    private func exchange(code: String, verifier: String) async throws -> Tokens {
        let fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "client_id": configuration.clientID,
            "code_verifier": verifier,
        ]
        return try await postTokenRequest(fields, fallbackRefreshToken: nil)
    }

    // MARK: - Token lifecycle

    /// A valid access token, refreshing first if the stored one is near expiry.
    public func validAccessToken() async throws -> String {
        lock.lock()
        let tokens = cachedTokens
        lock.unlock()

        guard let tokens else { throw PresenceSourceError.notAuthorized }
        guard tokens.isExpired else { return tokens.accessToken }
        return try await refresh().accessToken
    }

    @discardableResult
    public func refresh() async throws -> Tokens {
        lock.lock()
        let existing = cachedTokens
        lock.unlock()
        guard let existing else { throw PresenceSourceError.notAuthorized }

        Log.oauth.info("refreshing Spotify access token")
        let fields = [
            "grant_type": "refresh_token",
            "refresh_token": existing.refreshToken,
            "client_id": configuration.clientID,
        ]
        do {
            let tokens = try await postTokenRequest(fields, fallbackRefreshToken: existing.refreshToken)
            store(tokens)
            return tokens
        } catch let error as AuthError {
            // A refusal here means the grant is gone (revoked, or the user changed their
            // password). Drop the tokens so the UI can ask for a fresh sign-in rather than
            // retrying a refresh that can never succeed.
            if case .tokenExchangeFailed = error {
                Log.oauth.error("refresh rejected; clearing stored Spotify tokens")
                signOut()
                throw PresenceSourceError.authorizationExpired
            }
            throw error
        }
    }

    /// Spotify may omit `refresh_token` on a refresh response; keep the previous one when
    /// it does rather than losing the grant.
    private func postTokenRequest(_ fields: [String: String],
                                  fallbackRefreshToken: String?) async throws -> Tokens {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw PresenceSourceError.network(error.localizedDescription) }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.tokenExchangeFailed("malformed response")
        }
        guard http.statusCode == 200 else {
            // Body may contain error/error_description. It never contains a token.
            let detail = (try? JSONDecoder().decode(TokenErrorBody.self, from: data))
                .map { $0.error_description ?? $0.error } ?? "HTTP \(http.statusCode)"
            Log.oauth.error("token endpoint returned \(http.statusCode, privacy: .public): \(detail ?? "-", privacy: .public)")
            throw AuthError.tokenExchangeFailed(detail ?? "HTTP \(http.statusCode)")
        }

        let body = try JSONDecoder().decode(TokenResponseBody.self, from: data)
        guard let refreshToken = body.refresh_token ?? fallbackRefreshToken else {
            throw AuthError.tokenExchangeFailed("no refresh token returned")
        }
        return Tokens(accessToken: body.access_token,
                      refreshToken: refreshToken,
                      expiresAt: Date().addingTimeInterval(TimeInterval(body.expires_in)),
                      scope: body.scope ?? configuration.scopes.joined(separator: " "))
    }

    private struct TokenResponseBody: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
    }

    private struct TokenErrorBody: Decodable {
        let error: String?
        let error_description: String?
    }
}
