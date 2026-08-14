import Combine
import Foundation

/// Composition root. Owns the long-lived objects and wires them together, so the SwiftUI
/// layer can stay declarative and the tests can build the pieces individually.
@MainActor
public final class AppEnvironment: ObservableObject {

    public let settings: AppSettings
    public let accessibility: TeamsAccessibility
    public let target: TeamsAXTarget
    public let coordinator: PresenceCoordinator
    public let loginItem: LoginItemService
    public let spotifyAuth: SpotifyAuth

    private let webSource: SpotifyWebAPISource
    private let localSource: SpotifyLocalSource
    private var cancellables: Set<AnyCancellable> = []

    /// `nil` when no Spotify client ID is configured — the UI turns this into actionable
    /// setup instructions rather than a mysterious failure.
    public let configurationProblem: String?

    public init(settings: AppSettings? = nil) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        self.accessibility = TeamsAccessibility()
        self.target = TeamsAXTarget(accessibility: accessibility)
        self.loginItem = LoginItemService()

        let clientID = AppConfiguration.spotifyClientID
        self.configurationProblem = clientID == nil ? AppConfiguration.missingClientIDMessage : nil

        let configuration = SpotifyAuth.Configuration(
            clientID: clientID ?? "",
            redirectURI: AppConfiguration.spotifyRedirectURI
        )
        self.spotifyAuth = SpotifyAuth(configuration: configuration)
        self.webSource = SpotifyWebAPISource(auth: spotifyAuth)
        self.localSource = SpotifyLocalSource()

        let initialSource: PresenceSource = settings.sourceKind == .spotifyLocal ? localSource : webSource
        self.coordinator = PresenceCoordinator(target: target, source: initialSource, settings: settings)

        // Keep the coordinator in step with preference changes.
        settings.$sourceKind
            .dropFirst()
            .sink { [weak self] kind in
                guard let self else { return }
                self.coordinator.setSource(kind == .spotifyLocal ? self.localSource : self.webSource)
            }
            .store(in: &cancellables)

        // Any of these changing means the coordinator/target need re-reading.
        let debounceChanges = settings.$debounce.map { _ in () }.eraseToAnyPublisher()
        let graceChanges = settings.$pauseGrace.map { _ in () }.eraseToAnyPublisher()
        let clearAfterChanges = settings.$clearAfter.map { _ in () }.eraseToAnyPublisher()
        let showWhenChanges = settings.$showWhenMessaged.map { _ in () }.eraseToAnyPublisher()

        Publishers.MergeMany([debounceChanges, graceChanges, clearAfterChanges, showWhenChanges])
            .dropFirst()
            .sink { [weak self] in self?.coordinator.applySettings() }
            .store(in: &cancellables)

        coordinator.isEnabled = settings.syncEnabled
        coordinator.$isEnabled
            .dropFirst()
            .sink { [weak settings] enabled in settings?.syncEnabled = enabled }
            .store(in: &cancellables)
    }

    public var activeSource: PresenceSource {
        settings.sourceKind == .spotifyLocal ? localSource : webSource
    }

    public var isSpotifyConnected: Bool {
        settings.sourceKind == .spotifyLocal ? localSource.isAuthorized : spotifyAuth.isAuthorized
    }

    /// Run the one-time and on-upgrade checks.
    public func performStartupChecks() async {
        await coordinator.runSelfTestIfNeeded()
    }

    public func connectSpotify() async throws {
        try await spotifyAuth.authorize()
        coordinator.refreshSoon()
    }

    public func disconnectSpotify() {
        spotifyAuth.signOut()
        coordinator.refreshSoon()
    }
}

/// Build-time configuration.
///
/// The Spotify **client ID is public by design** — a PKCE desktop app cannot keep a
/// secret and does not need one — so bundling it is safe and expected. The client
/// *secret* is never referenced anywhere in this application.
public enum AppConfiguration {

    public static let spotifyRedirectURI = URL(string: "http://127.0.0.1:8888/callback")!

    /// Resolution order:
    ///  1. `SPOTIFY_CLIENT_ID` in the environment (development);
    ///  2. `SpotifyClientID` in Info.plist (how a release build ships it);
    ///  3. a local `Config/Spotify.plist`, which is git-ignored (contributor convenience).
    public static var spotifyClientID: String? {
        if let value = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"],
           !value.isEmpty { return value }

        if let value = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
           !value.isEmpty, !value.hasPrefix("$(") { return value }

        if let url = Bundle.main.url(forResource: "Spotify", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let value = plist["ClientID"] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    public static let missingClientIDMessage =
        "No Spotify client ID is configured. Create an app at developer.spotify.com, add "
        + "http://127.0.0.1:8888/callback as a redirect URI, then set SPOTIFY_CLIENT_ID "
        + "before launching. See README.md."
}
