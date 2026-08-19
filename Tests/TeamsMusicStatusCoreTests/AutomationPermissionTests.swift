import XCTest
@testable import TeamsMusicStatusCore

/// The v1.0.1 first-run blocker, pinned.
///
/// Onboarding showed "Spotify is not connected" and macOS never displayed the Automation
/// prompt. Two separate defects combined: the source resolution below silently selected
/// the Web API for any profile that had completed onboarding before, and the app could not
/// tell "never asked" apart from "refused" once a read did fail.
final class AutomationPermissionTests: XCTestCase {

    // MARK: Consent classification

    /// -1743 and -1744 are the whole point. `NSAppleScript` reports both as -1743, which
    /// is why a fresh user and a blocked user produced identical, unactionable copy.
    func testNeverAskedIsNotTheSameAsRefused() {
        XCTAssertEqual(SpotifyAutomation.classify(OSStatus(errAEEventWouldRequireUserConsent)), .notDetermined)
        XCTAssertEqual(SpotifyAutomation.classify(OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertNotEqual(SpotifyAutomation.classify(OSStatus(errAEEventWouldRequireUserConsent)),
                          SpotifyAutomation.classify(OSStatus(errAEEventNotPermitted)))
    }

    func testGrantedAndNotRunningAreDistinct() {
        XCTAssertEqual(SpotifyAutomation.classify(noErr), .granted)
        XCTAssertEqual(SpotifyAutomation.classify(OSStatus(procNotFound)), .targetNotRunning)
    }

    /// An unrecognised status must be carried verbatim, never rounded down to "denied" —
    /// a transient failure presented as a permission problem sends the user to System
    /// Settings to fix something that was never broken.
    func testUnknownStatusIsCarriedNotGuessed() {
        XCTAssertEqual(SpotifyAutomation.classify(OSStatus(-1712)), .unknown(-1712))
        XCTAssertNotEqual(SpotifyAutomation.classify(OSStatus(-1712)), .denied)
    }

    func testOnlyGrantedIsUsable() {
        XCTAssertTrue(SpotifyAutomation.classify(noErr).isUsable)
        for status in [errAEEventNotPermitted, errAEEventWouldRequireUserConsent, procNotFound] {
            XCTAssertFalse(SpotifyAutomation.classify(OSStatus(status)).isUsable)
        }
    }

    // MARK: The copy that made this unreportable

    /// The Web API source is what produced the misleading message a user saw when their
    /// profile had selected a source that never contacts Spotify. Pinned so nobody
    /// "improves" the string without realising a first-run user could see it.
    ///
    /// The source-*selection* contract that put them there is covered by
    /// `SourceMigrationRepairTests` in OnboardingReachabilityTests.swift — deliberately
    /// not duplicated here, so the two files cannot drift into contradicting each other.
    func testWebAPINotAuthorizedIsTheStringUsersReported() {
        XCTAssertEqual(PresenceSourceError.notAuthorized.errorDescription, "Spotify is not connected.")
    }
}
