import Combine
import Foundation

/// User preferences. Non-sensitive only — tokens live in the Keychain, never here.
///
/// Nothing in this type is persisted across a crash beyond plain preferences: the
/// previous Teams status is deliberately kept in memory only, so a crash can never cause
/// the app to overwrite a status the user has since set by hand with a stale value.
@MainActor
public final class AppSettings: ObservableObject {

    private enum Key {
        static let sourceKind = "sourceKind"
        /// Set only when the *user* picks a source, never by migration.
        static let sourceChosenExplicitly = "sourceChosenExplicitly"
        static let template = "statusTemplate"
        static let pauseGrace = "pauseGraceSeconds"
        static let debounce = "debounceSeconds"
        static let pollInterval = "pollIntervalSeconds"
        static let syncEnabled = "syncEnabled"
        static let clearAfter = "clearAfter"
        static let showWhenMessaged = "showWhenMessaged"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let maskProfanity = "maskProfanity"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            // sourceKind is deliberately NOT registered — see `resolveSourceKind`.
            Key.template: StatusTemplate.defaultTemplate,
            Key.pauseGrace: 300.0,
            Key.debounce: 5.0,
            Key.pollInterval: 3.0,
            Key.syncEnabled: false,
            Key.clearAfter: "Never",
            Key.showWhenMessaged: true,
            Key.hasCompletedOnboarding: false,
            // Defaults on. This writes to a work profile visible to an entire
            // organisation, and a track title is not something the user chose.
            Key.maskProfanity: true,
        ])
        self.sourceKind = Self.storedSourceKind(defaults)
        self.template = StatusTemplate(defaults.string(forKey: Key.template) ?? StatusTemplate.defaultTemplate)
        self.pauseGrace = defaults.double(forKey: Key.pauseGrace)
        self.debounce = defaults.double(forKey: Key.debounce)
        self.pollInterval = defaults.double(forKey: Key.pollInterval)
        self.syncEnabled = defaults.bool(forKey: Key.syncEnabled)
        self.clearAfter = defaults.string(forKey: Key.clearAfter) ?? "Never"
        self.showWhenMessaged = defaults.bool(forKey: Key.showWhenMessaged)
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.maskProfanity = defaults.bool(forKey: Key.maskProfanity)
    }

    /// Decide which source this install should use, preserving what an existing user had.
    ///
    /// Local Spotify is the default for anyone new, because it is the only source that can
    /// serve an arbitrary user: a Spotify Web API app in development mode is limited to
    /// five manually-allowlisted accounts, and extended quota is open only to registered
    /// organisations with 250k monthly actives. No way of packaging a bundled client ID
    /// changes that.
    ///
    /// But an existing user who never opened Settings has no stored source — they were on
    /// the Web API only because that used to be the default. Flipping the default would
    /// silently move them to local-only playback with primary-artist-only metadata, a
    /// downgrade they did not ask for. So their previous source is written down explicitly
    /// the first time this runs:
    ///
    ///   * fresh install           -> Local
    ///   * existing, never chose   -> Web API, recorded so later default changes cannot
    ///                                move them again
    ///   * chose either explicitly -> left alone
    ///
    /// `sourceKind` is deliberately absent from `register(defaults:)`. The registration
    /// domain is process-wide, so a registered value makes `string(forKey:)` non-nil for
    /// everyone and the question "has the user ever chosen?" becomes unanswerable — which
    /// is exactly how the first version of this silently did nothing.
    ///
    /// Keyed on `hasCompletedOnboarding` rather than on stored Spotify tokens: someone who
    /// connected Spotify and later disconnected still expects the source they were using,
    /// and someone part-way through onboarding is better served by the new default.
    /// The source to start with, read from preferences alone.
    ///
    /// **No Keychain access.** This runs inside SwiftUI's `@StateObject` construction on
    /// the main thread during launch, and `SecItemCopyMatching` can block indefinitely on
    /// securityd — a menu-bar app has no window to host the resulting prompt, so it simply
    /// hangs with no UI and no logs. `SpotifyAuth.init` documents the same hazard and the
    /// same reason. Anything that needs credentials happens in `repairSourceKind`, after
    /// launch, off the main thread.
    static func storedSourceKind(_ defaults: UserDefaults) -> PresenceSourceKind {
        if let stored = defaults.string(forKey: Key.sourceKind),
           let kind = PresenceSourceKind(rawValue: stored) {
            return kind
        }
        return .spotifyLocal
    }

    /// Apply the credential-dependent migration and repair.
    ///
    /// Call once after launch with `hasWebAPICredentials` already determined off the main
    /// thread. Writes preferences directly rather than through `sourceKind`'s setter,
    /// because that setter marks the value as the user's explicit choice — and this is the
    /// app correcting its own state, which is precisely what must stay distinguishable.
    public func repairSourceKind(hasWebAPICredentials: Bool) {
        let resolved = Self.resolveSourceKind(defaults,
                                              hasWebAPICredentials: { hasWebAPICredentials })
        guard resolved != sourceKind else { return }
        isApplyingRepair = true
        sourceKind = resolved
        isApplyingRepair = false
    }

    /// True while the app is correcting its own state, so the write below is not mistaken
    /// for the user picking a source.
    private var isApplyingRepair = false

    static func resolveSourceKind(
        _ defaults: UserDefaults,
        hasWebAPICredentials: () -> Bool = { SpotifyAuth.hasStoredCredentials() }
    ) -> PresenceSourceKind {
        if let stored = defaults.string(forKey: Key.sourceKind),
           let kind = PresenceSourceKind(rawValue: stored) {
            // Repair an install that was moved to the Web API by the flag above and has no
            // credentials to use it with — but never one where the user chose it.
            //
            // Without that second condition the repair is itself a bug: someone who picks
            // the Web API in Settings intending to connect next, quits, and relaunches
            // finds their choice silently reverted, every time. Repair is for state the
            // app invented, not for decisions the user made. That combination cannot work: the Web API source
            // without tokens reports "Spotify is not connected" and never contacts Spotify,
            // so macOS is never asked for Automation and the local path is never reached.
            // Someone in that state cannot recover by reinstalling, because the stored
            // source outlives the app, and clearing the onboarding flag alone leaves it in
            // place. Sending them to the source that needs no setup is the only exit.
            let chosenByUser = defaults.bool(forKey: Key.sourceChosenExplicitly)
            if kind == .spotifyWebAPI && !chosenByUser && !hasWebAPICredentials() {
                defaults.set(PresenceSourceKind.spotifyLocal.rawValue, forKey: Key.sourceKind)
                Log.coordinator.info("moved to the local source: the stored Web API source has no credentials")
                return .spotifyLocal
            }
            return kind
        }
        // Keyed on credentials, not on the onboarding flag.
        //
        // The flag was the wrong signal: "Set up later" recorded it without the user
        // configuring anything, so installs that had never touched the Web API were
        // migrated onto it. A refresh token is the only real evidence that someone was
        // using it.
        guard hasWebAPICredentials() else { return .spotifyLocal }
        defaults.set(PresenceSourceKind.spotifyWebAPI.rawValue, forKey: Key.sourceKind)
        Log.coordinator.info("preserved the Spotify Web API source for an install that has credentials")
        return .spotifyWebAPI
    }

    @Published public var sourceKind: PresenceSourceKind {
        // Property observers do not run during `init`, so this fires only when something
        // changes the source *after* launch — which is the user, in Settings. That is what
        // separates a deliberate choice from a value the migration wrote on their behalf,
        // and it is what stops the repair below from reverting someone every launch.
        didSet {
            defaults.set(sourceKind.rawValue, forKey: Key.sourceKind)
            if !isApplyingRepair {
                defaults.set(true, forKey: Key.sourceChosenExplicitly)
            }
        }
    }

    @Published public var template: StatusTemplate {
        didSet { defaults.set(template.raw, forKey: Key.template) }
    }

    /// Seconds playback may be paused/absent before the previous status is restored.
    @Published public var pauseGrace: TimeInterval {
        didSet { defaults.set(pauseGrace, forKey: Key.pauseGrace) }
    }

    /// Seconds a new status must stay stable before it is written.
    @Published public var debounce: TimeInterval {
        didSet { defaults.set(debounce, forKey: Key.debounce) }
    }

    @Published public var pollInterval: TimeInterval {
        didSet { defaults.set(pollInterval, forKey: Key.pollInterval) }
    }

    @Published public var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: Key.syncEnabled) }
    }

    @Published public var clearAfter: String {
        didSet { defaults.set(clearAfter, forKey: Key.clearAfter) }
    }

    @Published public var showWhenMessaged: Bool {
        didSet { defaults.set(showWhenMessaged, forKey: Key.showWhenMessaged) }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Mask common profanity in track, artist and album names before writing to Teams.
    @Published public var maskProfanity: Bool {
        didSet { defaults.set(maskProfanity, forKey: Key.maskProfanity) }
    }

    public var syncConfiguration: SyncEngine.Configuration {
        SyncEngine.Configuration(debounce: debounce, pauseGrace: pauseGrace)
    }

    /// Human-readable choices for the pause grace period.
    public static let pauseGraceChoices: [(label: String, seconds: TimeInterval)] = [
        ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300),
        ("15 minutes", 900), ("Never", .greatestFiniteMagnitude),
    ]
}
