import XCTest
@testable import TeamsMusicStatusCore

/// The "install once and forget it" contract, in the two places it is decidable without a
/// running Mac: what launch-at-login does on a fresh install versus an existing one, and
/// what the user is told while recovery is happening.
final class InstallOnceTests: XCTestCase {

    private func defaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Launch at login

    /// A fresh install has expressed no preference, so the post-onboarding default applies.
    /// Without this the app never comes back after a reboot and the user has to notice.
    @MainActor
    func testFreshInstallHasNotChosen() {
        let settings = AppSettings(defaults: defaults("tms.tests.launch.fresh"))
        XCTAssertFalse(settings.launchAtLoginChosenExplicitly)
    }

    /// Turning it off is a decision, and decisions outlive defaults. This is the assertion
    /// that stops a future "enable by default" from silently undoing someone's choice.
    @MainActor
    func testTurningItOffIsRemembered() {
        let d = defaults("tms.tests.launch.off")
        let settings = AppSettings(defaults: d)
        settings.launchAtLoginChosenExplicitly = true
        XCTAssertTrue(AppSettings(defaults: d).launchAtLoginChosenExplicitly,
                      "the choice must survive a relaunch")
    }

    /// And it must be per-install state, not a process-wide default that leaks between
    /// profiles — the same mistake `sourceKind` documents in `register(defaults:)`.
    @MainActor
    func testTheChoiceIsNotSharedBetweenProfiles() {
        let chosen = AppSettings(defaults: defaults("tms.tests.launch.a"))
        chosen.launchAtLoginChosenExplicitly = true
        let untouched = AppSettings(defaults: defaults("tms.tests.launch.b"))
        XCTAssertFalse(untouched.launchAtLoginChosenExplicitly)
    }

    // MARK: Recovery is never an indefinite shrug

    /// Every recovery state must say something specific. "Trying to recover" forever is
    /// indistinguishable from being stuck, which is exactly how this failed in the field.
    func testEveryRecoveryStateExplainsItself() {
        let states: [AppState] = [.teamsRestartedAutomatically, .recoveryDeferredForCall,
                                  .recoveryCoolingDown, .recoveryExhausted]
        for state in states {
            XCTAssertFalse(state.title.isEmpty, "\(state) has no title")
            XCTAssertFalse(state.detail?.isEmpty ?? true, "\(state) has no detail")
            XCTAssertNotEqual(state.title, AppState.recovering.title,
                              "\(state) must not read as the generic recovering state")
        }
    }

    /// Only the exhausted state asks the user to do anything. If waiting for a call or
    /// cooling down demanded action, the app would be crying wolf during normal operation.
    func testOnlyExhaustedRecoveryAsksTheUserToAct() {
        XCTAssertTrue(AppState.recoveryExhausted.needsUserAction)
        XCTAssertFalse(AppState.teamsRestartedAutomatically.needsUserAction)
        XCTAssertFalse(AppState.recoveryDeferredForCall.needsUserAction)
        XCTAssertFalse(AppState.recoveryCoolingDown.needsUserAction)
    }

    /// The final fallback has to tell the user the one thing that actually works. This is
    /// the message that would have saved 45 minutes of the app looping.
    func testExhaustedRecoveryNamesTheFix() {
        let detail = AppState.recoveryExhausted.detail ?? ""
        XCTAssertTrue(detail.lowercased().contains("quit"), detail)
        XCTAssertTrue(detail.lowercased().contains("teams"), detail)
    }
}
