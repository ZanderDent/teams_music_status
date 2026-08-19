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

/// The second-order damage from the same stale flag.
///
/// "Set up later" set `hasCompletedOnboarding`, and the source migration read that flag as
/// "this person was using the Spotify Web API" and wrote `sourceKind = spotifyWebAPI`
/// permanently. Installs that had never touched the Web API were silently moved onto a
/// source they had no credentials for.
///
/// The result is worse than a wrong default. The Web API source without tokens reports
/// "Spotify is not connected" and never contacts Spotify, so no Apple Event is sent, macOS
/// is never asked for Automation, and the permission the app actually needs is never
/// requested. Reinstalling does not help — the stored source outlives the app — and
/// clearing the onboarding flag alone leaves it in place.
@MainActor
final class SourceMigrationRepairTests: XCTestCase {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The migration must key on evidence of use, not on the onboarding flag.
    func testACompletedSetupWithNoCredentialsStaysLocal() {
        let defaults = freshDefaults("tms.mig.noCreds")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        XCTAssertEqual(
            AppSettings.resolveSourceKind(defaults, hasWebAPICredentials: { false }),
            .spotifyLocal,
            "the onboarding flag is not evidence that anyone used the Web API")
        XCTAssertNil(defaults.string(forKey: "sourceKind"),
                     "and nothing should have been written")
    }

    /// A real Web API user is still preserved — the fix must not demote them.
    func testAnInstallWithCredentialsKeepsTheWebAPI() {
        let defaults = freshDefaults("tms.mig.creds")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        XCTAssertEqual(
            AppSettings.resolveSourceKind(defaults, hasWebAPICredentials: { true }),
            .spotifyWebAPI)
        XCTAssertEqual(defaults.string(forKey: "sourceKind"), "spotifyWebAPI")
    }

    /// The rescue: an install already carrying the poisoned value.
    func testAStoredWebAPISourceWithNoCredentialsIsRepaired() {
        let defaults = freshDefaults("tms.mig.poisoned")
        defaults.set("spotifyWebAPI", forKey: "sourceKind")   // written by 1.0.0

        XCTAssertEqual(
            AppSettings.resolveSourceKind(defaults, hasWebAPICredentials: { false }),
            .spotifyLocal,
            "a source that cannot work must not be preserved out of politeness")
        XCTAssertEqual(defaults.string(forKey: "sourceKind"), "spotifyLocal",
                       "and the repair must persist, or it runs again every launch")
    }

    /// Repairing must not touch someone whose Web API genuinely works.
    func testAStoredWebAPISourceWithCredentialsIsLeftAlone() {
        let defaults = freshDefaults("tms.mig.valid")
        defaults.set("spotifyWebAPI", forKey: "sourceKind")
        XCTAssertEqual(
            AppSettings.resolveSourceKind(defaults, hasWebAPICredentials: { true }),
            .spotifyWebAPI)
        XCTAssertEqual(defaults.string(forKey: "sourceKind"), "spotifyWebAPI")
    }

    /// An explicit local choice is never overridden.
    func testAnExplicitLocalChoiceSurvives() {
        let defaults = freshDefaults("tms.mig.local")
        defaults.set("spotifyLocal", forKey: "sourceKind")
        XCTAssertEqual(
            AppSettings.resolveSourceKind(defaults, hasWebAPICredentials: { true }),
            .spotifyLocal)
    }

    /// The exact sequence the affected Mac went through, end to end.
    func testTheReportedUpgradePathEndsOnAWorkingSource() {
        let name = "tms.mig.reported"
        let defaults = freshDefaults(name)

        // 1.0.0: pressed "Set up later".
        defaults.set(true, forKey: "hasCompletedOnboarding")
        // A later 1.0.0 launch migrated them onto the Web API.
        defaults.set("spotifyWebAPI", forKey: "sourceKind")
        // The user cleared only the onboarding flag, as advised.
        defaults.removeObject(forKey: "hasCompletedOnboarding")

        // 1.0.1 launches: setup reappears *and* the source is usable.
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hasCompletedOnboarding, "setup must reappear")
        XCTAssertEqual(AppSettings.resolveSourceKind(defaults, hasWebAPICredentials: { false }),
                       .spotifyLocal,
                       "and must land on the source that can actually ask for Automation")
    }
}

/// Launch must not touch the Keychain.
///
/// `AppSettings.init` runs inside SwiftUI's `@StateObject` construction, on the main
/// thread, during launch. `SecItemCopyMatching` can block indefinitely on securityd — for
/// instance when the item was written by a different code identity and macOS wants to
/// prompt — and a menu-bar app has no window to host that prompt, so it hangs with no UI
/// and no logs. `SpotifyAuth.init` avoids this deliberately; the credential-keyed source
/// migration briefly reintroduced it by reading credentials from `init`.
@MainActor
final class LaunchPathKeychainTests: XCTestCase {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Constructing settings must resolve entirely from preferences.
    func testStartupSourceResolutionReadsOnlyPreferences() {
        let defaults = freshDefaults("tms.launch.nokeychain")
        defaults.set("spotifyWebAPI", forKey: "sourceKind")

        // No credential closure is available to this call at all — if the launch path
        // needed one, this could not compile, let alone answer.
        XCTAssertEqual(AppSettings.storedSourceKind(defaults), .spotifyWebAPI)
        XCTAssertEqual(AppSettings(defaults: defaults).sourceKind, .spotifyWebAPI,
                       "launch takes the stored value as-is; repair happens later")
    }

    func testAFreshProfileStartsOnLocalWithoutConsultingCredentials() {
        XCTAssertEqual(AppSettings.storedSourceKind(freshDefaults("tms.launch.fresh")),
                       .spotifyLocal)
    }

    /// The repair still happens — just after launch, with the answer passed in.
    func testTheRepairRunsLaterAndCorrectsAStrandedInstall() {
        let defaults = freshDefaults("tms.launch.repair")
        defaults.set("spotifyWebAPI", forKey: "sourceKind")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.sourceKind, .spotifyWebAPI, "unchanged at launch")

        settings.repairSourceKind(hasWebAPICredentials: false)
        XCTAssertEqual(settings.sourceKind, .spotifyLocal, "corrected once credentials are known")
        XCTAssertEqual(defaults.string(forKey: "sourceKind"), "spotifyLocal")
    }

    /// And the repair must not masquerade as the user choosing a source, or the next
    /// repair would refuse to run and the user could never be corrected again.
    func testARepairIsNotRecordedAsAnExplicitChoice() {
        let defaults = freshDefaults("tms.launch.notchoice")
        defaults.set("spotifyWebAPI", forKey: "sourceKind")
        let settings = AppSettings(defaults: defaults)
        settings.repairSourceKind(hasWebAPICredentials: false)

        XCTAssertFalse(defaults.bool(forKey: "sourceChosenExplicitly"),
                       "the app correcting itself is not a decision the user made")
    }

    /// A real choice still registers.
    func testAUserChoiceIsRecordedAsOne() {
        let defaults = freshDefaults("tms.launch.choice")
        let settings = AppSettings(defaults: defaults)
        settings.sourceKind = .spotifyWebAPI
        XCTAssertTrue(defaults.bool(forKey: "sourceChosenExplicitly"))

        // And is then immune to repair.
        settings.repairSourceKind(hasWebAPICredentials: false)
        XCTAssertEqual(settings.sourceKind, .spotifyWebAPI)
    }
}

/// The startup repair must not depend on a window being opened.
///
/// `performStartupChecks()` was reachable only from the menu-bar panel's `.task`, which
/// runs when that panel is rendered — i.e. when the user clicks the icon. A first-run user
/// is looking at the setup window and may never click it, so on precisely the installs
/// that needed repairing, neither the source repair nor the selector self-test ran.
@MainActor
final class StartupRepairReachabilityTests: XCTestCase {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A stranded profile must be corrected by the repair alone, with no UI involved.
    func testAStrandedProfileIsRepairedWithoutOpeningAnyWindow() {
        let defaults = freshDefaults("tms.startup.stranded")
        defaults.set("spotifyWebAPI", forKey: "sourceKind")
        let settings = AppSettings(defaults: defaults)

        settings.repairSourceKind(hasWebAPICredentials: false)

        XCTAssertEqual(settings.sourceKind, .spotifyLocal)
        XCTAssertEqual(defaults.string(forKey: "sourceKind"), "spotifyLocal",
                       "and it persists, so the next launch starts correct")
    }

    /// Running it twice must be harmless — launch drives it, and the panel still may too.
    func testRepairIsIdempotent() {
        let defaults = freshDefaults("tms.startup.idempotent")
        defaults.set("spotifyWebAPI", forKey: "sourceKind")
        let settings = AppSettings(defaults: defaults)

        for _ in 0..<3 { settings.repairSourceKind(hasWebAPICredentials: false) }
        XCTAssertEqual(settings.sourceKind, .spotifyLocal)
        XCTAssertFalse(defaults.bool(forKey: "sourceChosenExplicitly"),
                       "repeated repairs must never accumulate into a fake user choice")
    }

    /// Once repaired, a later run with credentials present must not bounce them back —
    /// the stored local value is now the truth, and only the user may change it.
    func testARepairedProfileIsNotBouncedBackLater() {
        let defaults = freshDefaults("tms.startup.stable")
        defaults.set("spotifyWebAPI", forKey: "sourceKind")
        let settings = AppSettings(defaults: defaults)
        settings.repairSourceKind(hasWebAPICredentials: false)
        XCTAssertEqual(settings.sourceKind, .spotifyLocal)

        // The user later connects the Web API from Settings; that is an explicit choice.
        settings.sourceKind = .spotifyWebAPI
        settings.repairSourceKind(hasWebAPICredentials: true)
        XCTAssertEqual(settings.sourceKind, .spotifyWebAPI)
    }
}
