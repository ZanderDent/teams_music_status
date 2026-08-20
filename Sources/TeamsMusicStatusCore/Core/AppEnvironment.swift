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

        Log.debug(Log.app, "AppEnvironment constructed (syncEnabled=\(settings.syncEnabled))")
        // Load stored Spotify credentials right after launch, off the main thread.
        //
        // This deliberately does NOT live in a view's `.task`: that only fires when the
        // menu-bar panel is first opened, and a user who never opens it got
        // "Spotify is not connected" forever while sync sat there doing nothing. It also
        // cannot go in SpotifyAuth.init, which runs on the main thread during SwiftUI
        // state construction and hung the app when securityd blocked.
        Task { [weak self] in
            guard let self else { return }
            let auth = self.spotifyAuth
            await Task.detached(priority: .utility) { auth.primeFromKeychain() }.value
            self.refreshSpotifyConnection()
            self.coordinator.refreshSoon()
        }

        coordinator.isEnabled = settings.syncEnabled
        coordinator.$isEnabled
            .dropFirst()
            .sink { [weak settings] enabled in settings?.syncEnabled = enabled }
            .store(in: &cancellables)
    }

    public var activeSource: PresenceSource {
        settings.sourceKind == .spotifyLocal ? localSource : webSource
    }

    public var isSpotifyConnected: Bool { spotifyConnected }

    /// Whether a Spotify connection is usable. Published so the UI updates once the
    /// Keychain has been read, which deliberately happens after launch (see SpotifyAuth).
    @Published public private(set) var spotifyConnected = false

    private var hasRunStartupChecks = false

    /// Run the on-upgrade checks. Off the launch critical path, but not dependent on any
    /// window being opened.
    ///
    /// This used to be reachable only from `MenuBarContentView`'s `.task`, which runs when
    /// the menu-bar panel is *rendered* — that is, when the user clicks the icon. A
    /// first-run user is looking at the setup window and may never open the panel, so on
    /// exactly the installs that need repairing most, neither the source repair nor the
    /// selector self-test ran at all. The app delegate now also drives this at launch.
    ///
    /// Idempotent: both callers are expected, and the second is a no-op.
    public func performStartupChecks() async {
        guard !hasRunStartupChecks else { return }
        hasRunStartupChecks = true
        await runStartupChecks()
    }

    private func runStartupChecks() async {
        // The source repair needs to know whether Web API credentials exist, which means
        // reading the Keychain — off the main thread, and only here. Doing it during
        // `AppSettings.init` would put a synchronous `SecItemCopyMatching` on the launch
        // path, which is the hang `SpotifyAuth.init` documents: securityd can block
        // indefinitely, and a menu-bar app has no window to host the prompt.
        let hasCredentials = await Task.detached(priority: .utility) {
            SpotifyAuth.hasStoredCredentials()
        }.value
        settings.repairSourceKind(hasWebAPICredentials: hasCredentials)

        refreshSpotifyConnection()
        await coordinator.runSelfTestIfNeeded()
    }

    public func refreshSpotifyConnection() {
        spotifyConnected = settings.sourceKind == .spotifyLocal
            ? localSource.isAuthorized
            : spotifyAuth.isAuthorized
    }

    public func connectSpotify() async throws {
        try await spotifyAuth.authorize()
        refreshSpotifyConnection()
        coordinator.refreshSoon()
    }

    /// Change launch-at-login, recording whether it was the user's decision.
    ///
    /// `userInitiated: false` is the post-onboarding default and deliberately does NOT set
    /// the flag, so a later change of default can still reach installs that never chose.
    public func setLaunchAtLogin(_ enabled: Bool, userInitiated: Bool = true) {
        if userInitiated { settings.launchAtLoginChosenExplicitly = true }
        loginItem.setEnabled(enabled)
    }

    /// Turn launch-at-login on for someone who has never expressed a preference. Called
    /// when onboarding completes, never afterwards, and never against an explicit choice.
    public func enableLaunchAtLoginByDefault() {
        guard !settings.launchAtLoginChosenExplicitly else {
            Log.app.info("leaving launch at login as the user set it")
            return
        }
        guard loginItem.isSupported, !loginItem.isEnabled else { return }
        Log.app.info("enabling launch at login by default after setup")
        loginItem.setEnabled(true)
    }

    public func disconnectSpotify() {
        spotifyAuth.signOut()
        refreshSpotifyConnection()
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
