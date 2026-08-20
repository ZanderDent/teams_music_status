import Foundation

/// Every state the app can be in, so the menu bar can say something specific instead of
/// "something went wrong".
public enum AppState: Equatable, Sendable {
    case disabled
    case ready
    case syncing
    case noPlayback

    case spotifyDisconnected
    case spotifyAuthExpired
    case spotifyPermissionMissing(String)
    case spotifyRateLimited(until: Date)
    case spotifyUnreachable(String)
    /// Local source only: macOS has not granted permission to control Spotify.
    /// Distinct from `spotifyPermissionMissing`, which is an OAuth scope problem —
    /// telling someone to "reconnect Spotify" when they actually need to tick a box in
    /// System Settings sends them somewhere useless.
    case spotifyAutomationDenied

    case teamsNotRunning
    case teamsAccessibilityPermissionMissing
    case teamsAccessibilityTreeUnavailable
    case teamsSignedOut
    case teamsMinimized
    case teamsSelectorsChanged(String)

    case manualOverrideDetected(String?)
    case recovering

    // Recovery is no longer a single indefinite "Reconnecting…". Each of these is a
    // distinct thing the app is doing or waiting on, because "trying to recover" forever
    // is indistinguishable from being stuck, and that is exactly how this looked when it
    // failed in the field.
    /// Teams was restarted automatically and is being given time to come back.
    case teamsRestartedAutomatically
    /// Recovery is deliberately deferred: something is capturing audio, so the user may be
    /// in a call and Teams must not be touched.
    case recoveryDeferredForCall
    /// A recovery action just ran; waiting out its cooldown before trying anything else.
    case recoveryCoolingDown
    /// Automated recovery has done everything it can. This is the only state that asks the
    /// user to act, and it is the last resort rather than the normal path.
    case recoveryExhausted

    /// Short label for the menu-bar header.
    public var title: String {
        switch self {
        case .disabled: return "Paused"
        case .ready: return "Active"
        case .syncing: return "Updating Teams…"
        case .noPlayback: return "Nothing playing"
        case .spotifyDisconnected: return "Spotify not connected"
        case .spotifyAuthExpired: return "Spotify sign-in expired"
        case .spotifyPermissionMissing: return "Spotify permission needed"
        case .spotifyRateLimited: return "Spotify rate limited"
        case .spotifyUnreachable: return "Spotify unreachable"
        case .spotifyAutomationDenied: return "Can't read Spotify"
        case .teamsNotRunning: return "Teams not running"
        case .teamsAccessibilityPermissionMissing: return "Needs Accessibility permission"
        case .teamsAccessibilityTreeUnavailable: return "Teams interface unavailable"
        case .teamsSignedOut: return "Teams is signed out"
        case .teamsMinimized: return "Teams is minimized"
        case .teamsSelectorsChanged: return "Teams UI changed"
        case .manualOverrideDetected: return "Manual status detected"
        case .recovering: return "Reconnecting…"
        case .teamsRestartedAutomatically: return "Restarted Teams"
        case .recoveryDeferredForCall: return "Waiting until your call ends"
        case .recoveryCoolingDown: return "Waiting before trying again"
        case .recoveryExhausted: return "Teams isn't responding"
        }
    }

    /// One sentence explaining what is happening and what, if anything, to do about it.
    public var detail: String? {
        switch self {
        case .disabled:
            return "Status sync is turned off."
        case .ready, .syncing:
            return nil
        case .noPlayback:
            return "Your Teams status will update when playback starts."
        case .spotifyDisconnected:
            return "Connect Spotify to start syncing."
        case .spotifyAuthExpired:
            return "Reconnect Spotify to continue."
        case .spotifyPermissionMissing(let detail):
            return "Reconnect Spotify to grant the missing permission (\(detail))."
        case .spotifyRateLimited(let until):
            let seconds = max(0, Int(until.timeIntervalSinceNow))
            return "Spotify asked us to slow down. Retrying in \(seconds)s."
        case .spotifyUnreachable(let detail):
            return detail
        case .spotifyAutomationDenied:
            return "Allow Teams Music Status to control Spotify in System Settings ▸ "
                 + "Privacy & Security ▸ Automation, or switch to the Spotify Web API source." 
        case .teamsNotRunning:
            return "Start Microsoft Teams to resume syncing."
        case .teamsAccessibilityPermissionMissing:
            return "Teams Music Status needs Accessibility permission to update your status."
        case .teamsAccessibilityTreeUnavailable:
            return "Teams is running but is not exposing its interface. Trying to recover."
        case .teamsMinimized:
            return "Teams is minimized. Updates are paused rather than pulling its window "
                 + "back in front of you — they resume as soon as you open Teams again."
        case .teamsSignedOut:
            return "Teams is asking you to sign in. Syncing is paused so it doesn't get in your way — it resumes on its own once you're back in."
        case .teamsSelectorsChanged(let detail):
            return "Teams' interface changed, so status automation has been paused. \(detail)"
        case .manualOverrideDetected(let found):
            return found.map { "You set your status to \"\($0)\". Automatic updates are paused." }
                ?? "You changed your Teams status. Automatic updates are paused."
        case .recovering:
            return "Restoring the connection to Teams."
        case .teamsRestartedAutomatically:
            return "Teams stopped responding, so it was restarted. Syncing will resume on its own."
        case .recoveryDeferredForCall:
            return "Teams needs restarting, but you may be on a call — this will wait until you're done."
        case .recoveryCoolingDown:
            return "Waiting a few minutes before trying to reconnect to Teams again."
        case .recoveryExhausted:
            // The only recovery state that asks anything of the user, reached only after
            // the automated escalations have all been tried and capped.
            return "Teams is not responding to accessibility. Quit and reopen Teams."
        }
    }

    /// Drives the menu-bar icon and colour.
    public enum Severity: Sendable { case active, idle, warning, error }

    public var severity: Severity {
        switch self {
        case .ready, .syncing: return .active
        // Automated recovery is not a fault the user has to care about: the app is
        // handling it, or deliberately waiting for their call to end.
        case .disabled, .noPlayback, .recovering,
             .teamsRestartedAutomatically, .recoveryDeferredForCall, .recoveryCoolingDown:
            return .idle
        case .spotifyRateLimited, .spotifyUnreachable, .manualOverrideDetected,
             .teamsNotRunning, .teamsAccessibilityTreeUnavailable, .teamsSignedOut, .teamsMinimized:
            return .warning
        case .spotifyDisconnected, .spotifyAuthExpired, .spotifyPermissionMissing,
             .spotifyAutomationDenied,
             .teamsAccessibilityPermissionMissing, .teamsSelectorsChanged,
             // The one recovery state that needs a person. `needsUserAction` keys on
             // .error, which is exactly right: everything above this has been tried.
             .recoveryExhausted:
            return .error
        }
    }

    /// Whether the user must do something before syncing can work.
    public var needsUserAction: Bool { severity == .error }
}
