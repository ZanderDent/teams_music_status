import Foundation

/// Decides whether the setup window should open at launch.
///
/// This lives apart from the app delegate for one reason: the decision is the entire
/// first-run experience, and it used to be three lines buried in a timer callback where
/// nothing could test it. A user who never sees this window never grants Accessibility,
/// never grants Automation, and owns a menu-bar icon that does nothing — with no error, no
/// prompt, and nothing on screen to explain it.
///
/// Reported from a second Mac on 1.0.0: the app launched straight to the menu bar and
/// asked for nothing. The cause was not that launch but an earlier one, where "Set up
/// later" recorded onboarding as *complete*. Preferences survive dragging an app to the
/// Trash, and the Accessibility grant survives reinstalling the same signed build, so
/// every subsequent install on that Mac inherited a state that said "already set up" —
/// and nothing in the app could reopen the window.
public enum OnboardingPolicy {

    public enum Reason: String, Equatable, Sendable {
        /// The user has not finished setup — a fresh install, or a deferred one.
        case setupNotCompleted
        /// Setup was completed once, but the grant it depends on is gone.
        case accessibilityMissing
    }

    public enum Decision: Equatable, Sendable {
        case show(Reason)
        case skip

        public var shouldShow: Bool { self != .skip }

        /// Safe to log: names the branch taken, carries nothing about the user.
        public var logDescription: String {
            switch self {
            case .show(let reason): return "showing setup (\(reason.rawValue))"
            case .skip: return "setup already complete, not showing"
            }
        }
    }

    /// Both conditions matter, and neither is sufficient alone.
    ///
    /// Completing setup is not a promise that the app still works: a user can revoke
    /// Accessibility in System Settings at any time, and without it nothing can be
    /// written. Treating "completed once" as final is what turns a revoked permission
    /// into a silently dead app.
    public static func decide(hasCompletedOnboarding: Bool,
                              hasAccessibility: Bool) -> Decision {
        if !hasCompletedOnboarding { return .show(.setupNotCompleted) }
        if !hasAccessibility { return .show(.accessibilityMissing) }
        return .skip
    }
}
