import Foundation

/// Persists just enough about the Teams status to survive a restart or a crash.
///
/// ## Why this exists
///
/// `savedUserStatus` — the status the user had before the app first wrote anything — was
/// originally kept only in memory. That is wrong across a relaunch, and it was observed
/// failing in acceptance testing: the app wrote `♪ Blow my mind — kage`, was restarted,
/// captured *its own leftover status* as "the user's original", and later restored to it.
/// Repeat that a few times and the user's real status is gone for good.
///
/// ## What is persisted, and what is not
///
/// Only two strings: the status the app last wrote, and the user's pre-app status. No
/// track history, nothing about playback, nothing sensitive.
///
/// ## Lifecycle
///
/// * **Written** every time the app successfully commits a status to Teams.
/// * **Read** once at launch, to seed the sync engine.
/// * **Cleared** when the app restores the previous status, when sync is disabled, and
///   when a manual override is acknowledged — i.e. whenever the app no longer owns the
///   Teams status.
///
/// ## Why persisting is safe here
///
/// The risk of persisting is stale data causing an unwanted overwrite. That cannot happen,
/// because the restored `lastWrittenByApp` is never trusted on its own: before the next
/// write the coordinator reads what Teams actually shows and compares. If they differ, the
/// user has taken over and the app stops rather than restoring anything. The persisted
/// value can therefore only ever make the app *more* careful, never less.
public struct RestoreStateStore {

    private enum Key {
        static let lastWritten = "restore.lastWrittenByApp"
        static let savedCaptured = "restore.savedUserStatusCaptured"
        static let savedValue = "restore.savedUserStatusValue"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The status the app last successfully wrote, if it still believes it owns Teams.
    public var lastWrittenByApp: String? {
        get { defaults.string(forKey: Key.lastWritten) }
        nonmutating set { defaults.set(newValue, forKey: Key.lastWritten) }
    }

    /// The user's pre-app status.
    ///
    /// Double optional, and the distinction matters: `nil` means "never captured, so we do
    /// not know what the user had", while `.some(nil)` means "captured, and they had no
    /// status" — which restores to *empty*, not to some earlier guess.
    public var savedUserStatus: String?? {
        get {
            guard defaults.bool(forKey: Key.savedCaptured) else { return nil }
            return .some(defaults.string(forKey: Key.savedValue))
        }
        nonmutating set {
            switch newValue {
            case .none:
                defaults.set(false, forKey: Key.savedCaptured)
                defaults.removeObject(forKey: Key.savedValue)
            case .some(let value):
                defaults.set(true, forKey: Key.savedCaptured)
                defaults.set(value, forKey: Key.savedValue)
            }
        }
    }

    public func load(into state: inout SyncEngine.State) {
        state.lastWrittenByApp = lastWrittenByApp
        state.savedUserStatus = savedUserStatus
    }

    public func save(from state: SyncEngine.State) {
        lastWrittenByApp = state.lastWrittenByApp
        savedUserStatus = state.savedUserStatus
    }

    /// Forget everything. Called once the app no longer owns the Teams status.
    public func clear() {
        defaults.removeObject(forKey: Key.lastWritten)
        defaults.removeObject(forKey: Key.savedCaptured)
        defaults.removeObject(forKey: Key.savedValue)
    }
}
