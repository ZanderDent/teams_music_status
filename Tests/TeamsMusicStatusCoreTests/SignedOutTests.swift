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

    // MARK: - What counts as "ours to close"

    /// Escape is only ever sent when one of these is on screen. The set has to cover the
    /// status *editor* as well as the profile flyout: Teams swaps the "Profile menu"
    /// dialog for the editor once the status field opens, and a guard that only knew about
    /// the profile menu refused to close an open editor. That left it up, which collapses
    /// the exposed tree to that dialog, and the stale-dialog recovery then raised the Teams
    /// window — reported as "Teams keeps foregrounding itself".
    func testOurStatusSurfacesCoverTheEditorAndNotJustTheFlyout() {
        let names = Set(TeamsSelectors.ourStatusSurfaces.map(\.name))
        XCTAssertTrue(names.contains("profileDialog"), "the flyout itself")
        XCTAssertTrue(names.contains("composeBox"), "the editor — the case that regressed")
        XCTAssertTrue(names.contains("statusReadout"), "the flyout after a status exists")
    }

    /// These gate a destructive key press, so every one must be specific to this app's
    /// status UI. Anything that could match a sign-in sheet would reopen the original bug.
    func testEveryStatusSurfaceIsSpecificToTheStatusUI() {
        for selector in TeamsSelectors.ourStatusSurfaces {
            let description = selector.describedAs.lowercased()
            let isSpecific = description.contains("profile menu")
                || description.contains("status")
            XCTAssertTrue(isSpecific,
                          "\(selector.name) is too generic to gate an Escape: \(selector.describedAs)")
        }
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

    /// Repeated Teams write failures settle at five minutes rather than one. When Teams
    /// accepts the interaction but never stores the status, retrying is pointless and
    /// driving its flyout every minute is what makes the app feel like it breaks Teams.
    func testTeamsFailuresSettleAtAFiveMinuteCooldown() {
        let cap = PresenceCoordinator.teamsFailureCooldown
        XCTAssertEqual(cap, 300)
        let settled = PresenceCoordinator.backoffInterval(base: 3, failures: 20, cap: cap)
        XCTAssertEqual(settled, 300)
        // It must actually reach the ceiling, not stall below it — with a 3s base and a
        // doubling per failure that needs enough headroom in the exponent.
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: 3, failures: 7, cap: cap), 192)
        XCTAssertEqual(PresenceCoordinator.backoffInterval(base: 3, failures: 8, cap: cap), 300)
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

/// A transient missing selector must not permanently switch syncing off.
final class SelectorFailureToleranceTests: XCTestCase {

    /// Reported as "it says manual mode and automatic updates are not turned on". A flyout
    /// left open by a crash collapses Teams' exposed tree, so the profile button cannot be
    /// found for a moment — and the first occurrence used to disable automatic updates
    /// outright, with no route back except noticing and re-enabling by hand.
    func testDisablingRequiresRepeatedFailures() {
        XCTAssertGreaterThan(PresenceCoordinator.selectorFailuresBeforeDisabling, 1,
                             "one transient failure must never disable syncing")
    }

    /// A real Teams UI change fails every attempt, so the threshold has to be low enough
    /// that it is still caught within a few poll intervals rather than thrashing for
    /// minutes against a UI that will never match.
    func testThresholdIsStillPromptForARealUIChange() {
        XCTAssertLessThanOrEqual(PresenceCoordinator.selectorFailuresBeforeDisabling, 6)
    }
}

/// The app must remember what it actually wrote, not what it asked to write.
final class WrittenStatusFidelityTests: XCTestCase {

    /// Sanitisation is not identity. Astral emoji are replaced with BMP equivalents the
    /// synthetic input path can deliver, whitespace is collapsed, and long text is clamped.
    func testSanitisationChangesTheStringItWrites() {
        let requested = "🎵 Dreams  by  Fleetwood Mac"
        let written = UnicodeSanitizer.clamp(UnicodeSanitizer.sanitize(requested).text)
        XCTAssertNotEqual(requested, written,
                          "if these were always equal the bug could not occur")
        XCTAssertFalse(written.contains("🎵"), "astral emoji cannot be typed and are replaced")
    }

    /// Recording the request rather than the result made the next poll compare Teams'
    /// actual text against text that was never sent, see a difference, and conclude the
    /// user had edited their status by hand — pausing automatic updates. Any track with an
    /// emoji in the title, or long enough to clamp, switched syncing off silently.
    func testComparingRequestAgainstWrittenTextWouldFalselyDetectAnOverride() {
        let requested = "🎵 Dreams by Fleetwood Mac"
        let written = UnicodeSanitizer.clamp(UnicodeSanitizer.sanitize(requested).text)

        // What Teams reports back is the written text.
        let observedInTeams = written

        XCTAssertNotEqual(observedInTeams, requested,
                          "comparing against the request is what produced the false override")
        XCTAssertEqual(observedInTeams, written,
                       "comparing against what was written is stable")
    }

    /// A clamped title must round-trip too — 280 characters is Teams' limit.
    func testClampedTitlesRoundTrip() {
        let long = String(repeating: "Very Long Title ", count: 40)
        let written = UnicodeSanitizer.clamp(UnicodeSanitizer.sanitize(long).text)
        XCTAssertLessThanOrEqual(written.count, TeamsSelectors.statusCharacterLimit)
        XCTAssertNotEqual(written, long)
        XCTAssertEqual(written, UnicodeSanitizer.clamp(UnicodeSanitizer.sanitize(written).text),
                       "re-sanitising what was written must be a no-op, or it can never match")
    }
}
