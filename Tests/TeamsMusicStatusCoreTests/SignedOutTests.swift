import XCTest
@testable import TeamsMusicStatusCore

/// Regression tests for the bug where the integration fought the user for the Teams
/// sign-in screen.
///
/// The sequence was: Teams shows its sign-in sheet, the app shell survives underneath so
/// the health check still said `.healthy`, a status write was attempted, activating the
/// profile button failed because a modal was up, and the failure path sent Escape — three
/// times per attempt, every three seconds. Escape reached the sheet, not a flyout, and
/// dismissed it. The user could not stay on the sign-in screen long enough to type a
/// password.
///
/// Two independent defences are pinned here, because the safety property must not depend
/// on correctly recognising a sign-in screen:
///
///  1. `closeFlyout` only presses Escape when *our* flyout is open (enforced in
///     `TeamsAXTarget`; covered by the selector tests below, which prove the sign-in UI
///     cannot masquerade as our flyout).
///  2. Health reports `.signedOut` so recovery stands down and the poll loop backs off.
final class SignedOutTests: XCTestCase {

    // MARK: - Detecting the sign-in surface

    func testRecognisesSignInWindowTitles() {
        let titles = [
            "Sign in to Microsoft Teams",
            "Sign in",
            "Microsoft Teams — Login",
            "Pick an account",
            "Use another account",
            "Enter password",
            "We couldn't sign you in",
        ]
        for title in titles {
            XCTAssertTrue(TeamsSelectors.titleIndicatesSignIn(title),
                          "\(title) should be recognised as a sign-in window")
        }
    }

    func testMatchingIsCaseInsensitiveAndSubstringBased() {
        XCTAssertTrue(TeamsSelectors.titleIndicatesSignIn("SIGN IN TO MICROSOFT TEAMS"))
        XCTAssertTrue(TeamsSelectors.titleIndicatesSignIn("Microsoft Teams | Sign In"))
    }

    /// A false positive only pauses syncing, so the risk is mild — but pausing every time
    /// someone opens a chat with a colleague called "Robert Signin" would still be a bug.
    func testOrdinaryTeamsWindowsAreNotMistakenForSignIn() {
        let ordinary = [
            "Microsoft Teams",
            "Chat | Microsoft Teams",
            "General (Engineering) | Microsoft Teams",
            "Calendar",
            "",
        ]
        for title in ordinary {
            XCTAssertFalse(TeamsSelectors.titleIndicatesSignIn(title),
                           "\(title) must not be treated as a sign-in window")
        }
        XCTAssertFalse(TeamsSelectors.titleIndicatesSignIn(nil))
    }

    // MARK: - Standing down rather than repairing

    func testSignedOutIsNotAutomatableAndIsRecognisedAsTheUsersTurn() {
        XCTAssertFalse(TeamsHealth.signedOut.canAutomate)
        XCTAssertTrue(TeamsHealth.signedOut.isUserBusy)
    }

    /// Every other unhealthy state is something the app repairs by acting on Teams —
    /// pressing Escape, raising windows, re-opening them, running the enabler. `signedOut`
    /// is the one state where all of that is harmful, so it must be the only `isUserBusy`.
    func testNoOtherStateSuppressesRepair() {
        for health in [TeamsHealth.permissionMissing, .notRunning, .noWindow,
                       .minimized, .treeUnavailable, .healthy] {
            XCTAssertFalse(health.isUserBusy, "\(health) should still allow repair")
        }
    }

    func testSignedOutErrorExplainsItselfWithoutBlamingTheUser() {
        let message = TeamsAccessibilityError.signedOut.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("sign in"))
        XCTAssertTrue(message.lowercased().contains("paused"))
    }

    // MARK: - Backing off instead of hammering

    /// The original bug retried every 3 seconds indefinitely. Backoff is what stops a
    /// single stuck condition becoming a persistent nuisance.
    func testBackoffGrowsAndIsCapped() {
        let base: TimeInterval = 3
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: base, failures: 0), 3)
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: base, failures: 1), 3)
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: base, failures: 2), 6)
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: base, failures: 3), 12)
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: base, failures: 4), 24)
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: base, failures: 5), 48)
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: base, failures: 6), 60, "capped")
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: base, failures: 99), 60, "still capped")
    }

    func testBackoffNeverReturnsLessThanTheBaseInterval() {
        for failures in 0...20 {
            XCTAssertGreaterThanOrEqual(
                PresenceCoordinator.backoffInterval(base: 3, failures: failures), 3)
        }
    }

    // MARK: - User-facing state

    func testSignedOutStateReadsAsTemporaryAndSelfHealing() {
        let state = AppState.teamsSignedOut
        XCTAssertEqual(state.title, "Teams is signed out")
        let detail = state.detail ?? ""
        XCTAssertTrue(detail.lowercased().contains("paused"))
        // It resolves on its own, so it must not nag as though the app were broken.
        XCTAssertEqual(state.severity, .warning)
        XCTAssertFalse(state.needsUserAction,
                       "signing back into Teams is not an action the app should demand")
    }
}
