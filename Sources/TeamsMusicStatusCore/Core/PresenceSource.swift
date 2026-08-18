import Foundation

/// Where presence comes from. Spotify is the only family implemented today; Apple Music,
/// editors and so on would satisfy the same contract without touching the coordinator.
public protocol PresenceSource: AnyObject {
    var kind: PresenceSourceKind { get }
    var displayName: String { get }

    /// Whether this source needs a sign-in before it can be used at all.
    var requiresAuthorization: Bool { get }

    /// Whether it is currently usable (credentials present, permissions granted).
    var isAuthorized: Bool { get }

    /// One reading. `nil` means "nothing is playing" — a normal, non-error state.
    func fetch() async throws -> TrackPresence?
}

/// Failure modes a source can report, shaped so the coordinator can decide between
/// "retry", "back off", and "stop and tell the user" without string matching.
public enum PresenceSourceError: LocalizedError, Equatable {
    /// No credentials at all — the user has never connected this source.
    case notAuthorized
    /// Credentials exist but are no longer valid and refresh did not help.
    case authorizationExpired
    /// The grant is missing a scope. Refreshing can never fix this; only re-authorising can.
    case permissionsMissing(String)
    case rateLimited(retryAfter: TimeInterval)
    case network(String)
    case serviceError(status: Int, message: String?)
    /// Local source only: the Spotify desktop app is not running.
    case appNotRunning
    /// Local source only: the Automation (Apple Events) grant was refused.
    case automationPermissionDenied
    /// Local source only: an Apple Event failed for a reason that is not a permission
    /// refusal. Carried separately so it can never be mistaken for silence.
    case appleEventFailure(code: Int, message: String)
    /// Local source only: the read did not come back in time. A hung Apple Event is not
    /// evidence that nothing is playing.
    case timedOut(seconds: TimeInterval)
    /// The source answered, but not in a shape we understand. A parse failure is a bug
    /// to fix, never a playback state to act on.
    case parseFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Spotify is not connected."
        case .authorizationExpired:
            return "Your Spotify sign-in has expired. Reconnect Spotify to continue."
        case .permissionsMissing(let detail):
            return "Spotify refused the request because a permission is missing (\(detail)). "
                 + "Reconnect Spotify to grant it."
        case .rateLimited(let retryAfter):
            return "Spotify is rate limiting requests. Retrying in \(Int(retryAfter))s."
        case .network(let detail):
            return "Could not reach Spotify: \(detail)"
        case .serviceError(let status, let message):
            return "Spotify returned an error (\(status))\(message.map { ": \($0)" } ?? "")."
        case .appNotRunning:
            return "The Spotify app is not running on this Mac."
        case .automationPermissionDenied:
            return "Permission to control Spotify was denied. Grant it in "
                 + "System Settings ▸ Privacy & Security ▸ Automation, then reopen this app."
        case .appleEventFailure(let code, let message):
            return "Could not read Spotify (Apple Event error \(code)): \(message)"
        case .timedOut(let seconds):
            return "Spotify did not answer within \(Int(seconds))s."
        case .parseFailure(let detail):
            return "Could not understand Spotify's answer: \(detail)"
        }
    }

    /// Whether retrying the same call unchanged could plausibly succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .network, .serviceError, .appNotRunning: return true
        // A failed or slow Apple Event usually succeeds on the next poll. Crucially these
        // are transient *errors*, not "nothing is playing" — the distinction the local
        // source used to lose.
        case .appleEventFailure, .timedOut: return true
        case .parseFailure: return false
        case .notAuthorized, .authorizationExpired, .permissionsMissing, .automationPermissionDenied: return false
        }
    }

    /// Whether the user must re-authorise before this source can work again.
    public var requiresReauthorization: Bool {
        switch self {
        case .authorizationExpired, .permissionsMissing: return true
        default: return false
        }
    }
}
