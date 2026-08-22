import Foundation
import TeamsMusicStatusCore

/// User preferences on Windows. Non-sensitive only — credentials live in Windows
/// Credential Manager, never here.
///
/// The macOS `AppSettings` is a Combine `ObservableObject` backed by `UserDefaults`.
/// Neither exists here, so this is a plain observable backed by a JSON file under
/// `%APPDATA%`. The property names, defaults and semantics are deliberately identical, so
/// the two platforms behave the same and a reader of one can follow the other.
///
/// As on macOS, **nothing about the previous Teams status is persisted**. A crash must
/// never let the app overwrite a status the user has since set by hand with a stale value;
/// the cost is that a crash loses the ability to restore, which is the safer failure.
public final class WindowsSettings: @unchecked Sendable {

    // MARK: - Stored form

    private struct Stored: Codable {
        var sourceKind: String?
        /// Set only when the *user* picks a source, never by migration.
        var sourceChosenExplicitly: Bool?
        var template: String?
        var pauseGrace: TimeInterval?
        var debounce: TimeInterval?
        var pollInterval: TimeInterval?
        var syncEnabled: Bool?
        var clearAfter: String?
        var showWhenMessaged: Bool?
        var hasCompletedOnboarding: Bool?
        var maskProfanity: Bool?
        var launchAtLogin: Bool?
        var lastVerifiedTeamsVersion: String?
    }

    private let fileURL: URL
    private let lock = NSRecursiveLock()
    private var stored: Stored

    /// Called after any change, on the caller's thread. The tray app uses this to refresh
    /// its menu and the coordinator to pick up a new template without a restart.
    public var onChange: (@Sendable () -> Void)?

    public static let defaultDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["APPDATA"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("TeamsMusicStatus")
    }()

    public init(directory: URL = WindowsSettings.defaultDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            self.stored = decoded
        } else {
            self.stored = Stored()
        }
    }

    // MARK: - Properties

    /// Which source feeds presence.
    ///
    /// Local is the default for anyone new, for the same reason as on macOS: a Spotify Web
    /// API app in development mode serves only five hand-allowlisted accounts, so it cannot
    /// serve an arbitrary user. On Windows the local source is also strictly better than
    /// its macOS counterpart — it reports the album and every artist.
    public var sourceKind: PresenceSourceKind {
        get { read { PresenceSourceKind(rawValue: $0.sourceKind ?? "") ?? .spotifyLocal } }
        set {
            write {
                $0.sourceKind = newValue.rawValue
                $0.sourceChosenExplicitly = true
            }
        }
    }

    /// Whether the user chose the source themselves, as opposed to the app picking it.
    /// Kept distinguishable so a future default change cannot silently move someone who
    /// made a deliberate choice.
    public var sourceChosenExplicitly: Bool {
        read { $0.sourceChosenExplicitly ?? false }
    }

    public var template: StatusTemplate {
        get { read { StatusTemplate($0.template ?? StatusTemplate.defaultTemplate) } }
        set { write { $0.template = newValue.raw } }
    }

    /// Seconds playback may be paused or absent before the previous status is restored.
    public var pauseGrace: TimeInterval {
        get { read { $0.pauseGrace ?? 300 } }
        set { write { $0.pauseGrace = newValue } }
    }

    /// Minimum gap between two Teams writes. Leading-edge, not trailing — see `SyncEngine`.
    public var debounce: TimeInterval {
        get { read { $0.debounce ?? 5 } }
        set { write { $0.debounce = newValue } }
    }

    public var pollInterval: TimeInterval {
        get { read { $0.pollInterval ?? 3 } }
        set { write { $0.pollInterval = newValue } }
    }

    public var syncEnabled: Bool {
        get { read { $0.syncEnabled ?? false } }
        set { write { $0.syncEnabled = newValue } }
    }

    public var clearAfter: String {
        get { read { $0.clearAfter ?? "Never" } }
        set { write { $0.clearAfter = newValue } }
    }

    public var showWhenMessaged: Bool {
        get { read { $0.showWhenMessaged ?? true } }
        set { write { $0.showWhenMessaged = newValue } }
    }

    public var hasCompletedOnboarding: Bool {
        get { read { $0.hasCompletedOnboarding ?? false } }
        set { write { $0.hasCompletedOnboarding = newValue } }
    }

    /// Mask common profanity in track, artist and album names before writing to Teams.
    ///
    /// Defaults on, as on macOS. This writes to a work profile visible to an entire
    /// organisation, and a track title is not something the user chose.
    public var maskProfanity: Bool {
        get { read { $0.maskProfanity ?? true } }
        set { write { $0.maskProfanity = newValue } }
    }

    public var launchAtLogin: Bool {
        get { read { $0.launchAtLogin ?? false } }
        set { write { $0.launchAtLogin = newValue } }
    }

    /// The Teams build whose UI was last confirmed to match `TeamsSelectors`.
    ///
    /// Teams updates itself silently and can move the controls this app navigates by. The
    /// self-test is expensive — it opens the flyout and the editor — so it runs when this
    /// stops matching the installed build rather than on every launch. That is the same
    /// trade `TeamsVersionTracker` makes on macOS.
    public var lastVerifiedTeamsVersion: String? {
        get { read { $0.lastVerifiedTeamsVersion } }
        set { write { $0.lastVerifiedTeamsVersion = newValue } }
    }

    public var syncConfiguration: SyncEngine.Configuration {
        SyncEngine.Configuration(debounce: debounce, pauseGrace: pauseGrace)
    }

    /// Human-readable choices for the pause grace period. Matches macOS.
    public static let pauseGraceChoices: [(label: String, seconds: TimeInterval)] = [
        ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300),
        ("15 minutes", 900), ("Never", .greatestFiniteMagnitude),
    ]

    // MARK: - Persistence

    private func read<T>(_ body: (Stored) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(stored)
    }

    private func write(_ mutate: (inout Stored) -> Void) {
        lock.lock()
        mutate(&stored)
        persist()
        lock.unlock()
        onChange?()
    }

    /// Written via a temporary file and an atomic replace, so a crash mid-write cannot
    /// leave a truncated settings file that fails to parse on next launch and silently
    /// resets everything the user configured.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Where settings live, for the diagnostics CLI and bug reports.
    public var location: URL { fileURL }
}
