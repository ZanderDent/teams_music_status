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
            Key.sourceKind: PresenceSourceKind.spotifyWebAPI.rawValue,
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
        self.sourceKind = PresenceSourceKind(rawValue: defaults.string(forKey: Key.sourceKind) ?? "")
            ?? .spotifyWebAPI
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

    @Published public var sourceKind: PresenceSourceKind {
        didSet { defaults.set(sourceKind.rawValue, forKey: Key.sourceKind) }
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
