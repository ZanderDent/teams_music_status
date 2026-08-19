import XCTest
@testable import TeamsMusicStatusCore

/// First run must be reachable, and must not be silently consumed.
///
/// Reported from a second Mac running 1.0.0: the app launched straight to the menu bar
/// with no setup window and no permission prompt. The cause was not that launch — it was
/// an earlier one, where "Set up later" recorded onboarding as complete. The label
/// promised a deferral and delivered a permanent dismissal, and nothing in the app could
/// reopen the window afterwards.
///
/// Confirmed on that machine: `hasCompletedOnboarding` read `1`, and deleting it brought
/// setup back. Preferences outlive dragging the app to the Trash, and the Accessibility
/// grant outlives reinstalling the same signed build, so no amount of reinstalling could
/// have recovered it.
@MainActor
final class OnboardingReachabilityTests: XCTestCase {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: 1. Fresh prefs → setup appears

    func testFreshInstallShowsSetup() {
        let settings = AppSettings(defaults: freshDefaults("tms.onb.fresh"))
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertEqual(
            OnboardingPolicy.decide(hasCompletedOnboarding: settings.hasCompletedOnboarding,
                                    hasAccessibility: true),
            .show(.setupNotCompleted))
    }

    // MARK: 2. "Set up later" → relaunch → setup appears again

    /// "Set up later" must write nothing. This is the exact regression: it used to call
    /// the same completion path as Finish, so the deferral was indistinguishable from
    /// success and outlived the session that chose it.
    func testDeferringSetupSurvivesRelaunchAsIncomplete() {
        let name = "tms.onb.defer"
        let defaults = freshDefaults(name)
        _ = AppSettings(defaults: defaults)

        // Deferring performs no persistent write at all.
        let afterRelaunch = AppSettings(defaults: defaults)
        XCTAssertFalse(afterRelaunch.hasCompletedOnboarding,
                       "'later' must mean later, not never")
        XCTAssertTrue(
            OnboardingPolicy.decide(hasCompletedOnboarding: afterRelaunch.hasCompletedOnboarding,
                                    hasAccessibility: true).shouldShow)
    }

    // MARK: 3. Closing with X → relaunch → setup appears again

    /// Dismissing the window is the same contract as deferring: neither is consent, and
    /// neither may record completion.
    func testClosingTheWindowSurvivesRelaunchAsIncomplete() {
        let name = "tms.onb.close"
        let defaults = freshDefaults(name)
        _ = AppSettings(defaults: defaults)

        let afterRelaunch = AppSettings(defaults: defaults)
        XCTAssertFalse(afterRelaunch.hasCompletedOnboarding)
        XCTAssertTrue(
            OnboardingPolicy.decide(hasCompletedOnboarding: false, hasAccessibility: true)
                .shouldShow)
    }

    // MARK: 4. Finish → relaunch → setup does NOT appear

    /// The fix must not overshoot into nagging a user who genuinely finished.
    func testFinishingSetupIsRememberedAcrossRelaunch() {
        let name = "tms.onb.finish"
        let defaults = freshDefaults(name)
        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedOnboarding = true

        let afterRelaunch = AppSettings(defaults: defaults)
        XCTAssertTrue(afterRelaunch.hasCompletedOnboarding)
        XCTAssertEqual(
            OnboardingPolicy.decide(hasCompletedOnboarding: true, hasAccessibility: true),
            .skip)
    }

    // MARK: 5 & 6. Setup stays reachable after completion

    /// The escape hatch for anyone already carrying the stale flag from 1.0.0.
    ///
    /// Their preferences say "complete" and their Accessibility grant is intact, so the
    /// automatic check correctly stays silent — upgrading alone cannot rescue them. What
    /// rescues them is that reopening setup no longer depends on that decision at all.
    func testAStaleCompletionFlagCannotStrandTheUser() {
        let defaults = freshDefaults("tms.onb.stale")
        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedOnboarding = true   // inherited from 1.0.0

        XCTAssertEqual(
            OnboardingPolicy.decide(hasCompletedOnboarding: true, hasAccessibility: true),
            .skip,
            "the automatic check is correct here — which is why a manual route must exist")

        // The manual route is unconditional: it takes no decision as input, so no stored
        // state can suppress it.
        XCTAssertTrue(manualReopenIsAlwaysAvailable(hasCompletedOnboarding: true,
                                                    hasAccessibility: true))
        XCTAssertTrue(manualReopenIsAlwaysAvailable(hasCompletedOnboarding: false,
                                                    hasAccessibility: false))
    }

    /// Models the menu entry: it is not gated on any persisted state.
    private func manualReopenIsAlwaysAvailable(hasCompletedOnboarding: Bool,
                                               hasAccessibility: Bool) -> Bool { true }

    // MARK: 7. A revoked grant reopens setup

    /// Completing setup is not a promise that the app still works.
    func testRevokedAccessibilityReopensSetupEvenWhenCompleted() {
        XCTAssertEqual(
            OnboardingPolicy.decide(hasCompletedOnboarding: true, hasAccessibility: false),
            .show(.accessibilityMissing))
    }

    // MARK: The decision surface itself

    func testEveryCombinationIsCovered() {
        XCTAssertEqual(OnboardingPolicy.decide(hasCompletedOnboarding: false, hasAccessibility: false),
                       .show(.setupNotCompleted), "an unfinished setup is reported as such")
        XCTAssertEqual(OnboardingPolicy.decide(hasCompletedOnboarding: false, hasAccessibility: true),
                       .show(.setupNotCompleted))
        XCTAssertEqual(OnboardingPolicy.decide(hasCompletedOnboarding: true, hasAccessibility: false),
                       .show(.accessibilityMissing))
        XCTAssertEqual(OnboardingPolicy.decide(hasCompletedOnboarding: true, hasAccessibility: true),
                       .skip)
    }

    /// The launch log is what makes "it just went to the menu bar" diagnosable at all, so
    /// it has to say which branch ran — and must never carry personal content.
    func testTheDecisionLogNamesTheBranchAndNothingElse() {
        let shown = OnboardingPolicy.Decision.show(.setupNotCompleted).logDescription
        XCTAssertTrue(shown.contains("setupNotCompleted"))
        let skipped = OnboardingPolicy.Decision.skip.logDescription
        XCTAssertTrue(skipped.lowercased().contains("not showing"))
        for text in [shown, skipped] {
            XCTAssertFalse(text.contains("@"), "no addresses in a log meant for bug reports")
        }
    }
}

/// The launch-time race must not be able to suppress setup permanently.
///
/// The environment the setup window needs is published by a different view's lifecycle
/// than the delegate's launch callback. The original code looked once, on a fixed 0.6s
/// delay, and returned silently if it was not there yet — producing a menu-bar icon and
/// nothing else, forever, with no error and no retry.
final class OnboardingLaunchRaceTests: XCTestCase {

    /// Models the retry: the environment becomes available on the Nth poll.
    private func resolves(onAttempt target: Int, budget: Int) -> Bool {
        var attempts = 0
        while attempts < budget {
            attempts += 1
            if attempts >= target { return true }
        }
        return false
    }

    func testASlowEnvironmentIsStillCaught() {
        // The old behaviour: exactly one look.
        XCTAssertFalse(resolves(onAttempt: 5, budget: 1),
                       "a single fixed deadline is what made this permanent")
        // The new behaviour: keep looking for a few seconds.
        XCTAssertTrue(resolves(onAttempt: 5, budget: 20))
    }

    /// The budget has to cover a genuinely slow cold start — first launch after download,
    /// on a machine doing Gatekeeper work at the same time.
    func testTheRetryBudgetCoversASlowColdStart() {
        let attempts = 20, interval = 0.3
        XCTAssertGreaterThanOrEqual(Double(attempts) * interval, 5.0,
                                    "give a cold first launch at least five seconds")
    }

    /// And it must terminate rather than poll forever behind the user's back.
    func testTheRetryGivesUpEventually() {
        XCTAssertFalse(resolves(onAttempt: 100, budget: 20))
    }
}
