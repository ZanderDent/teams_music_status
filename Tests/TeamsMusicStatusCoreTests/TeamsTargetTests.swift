import XCTest
@testable import TeamsMusicStatusCore

/// Pieces of the Teams target that can be tested without a running Teams.
final class TeamsStatusParsingTests: XCTestCase {

    /// Teams appends a second line whenever a clear duration is set. Only the first line
    /// is the status message; treating the whole value as the message would make every
    /// post-commit verification fail, and every manual-override check fire spuriously.
    func testOnlyTheFirstLineIsTheStatusMessage() {
        XCTAssertEqual(
            TeamsAXTarget.firstLine(of: "♪ Dreams — Fleetwood Mac\nDisplay until 8:27 AM"),
            "♪ Dreams — Fleetwood Mac")
    }

    func testSingleLineStatusIsUnchanged() {
        XCTAssertEqual(TeamsAXTarget.firstLine(of: "In the office"), "In the office")
    }

    func testTrailingNewlineIsTrimmed() {
        XCTAssertEqual(TeamsAXTarget.firstLine(of: "Listening to: House\n"), "Listening to: House")
    }

    func testEmptyOrWhitespaceMeansNoStatus() {
        XCTAssertNil(TeamsAXTarget.firstLine(of: ""))
        XCTAssertNil(TeamsAXTarget.firstLine(of: "   \n  "))
        XCTAssertNil(TeamsAXTarget.firstLine(of: nil))
    }
}

final class TeamsSelectorCatalogueTests: XCTestCase {

    /// The self-test names selectors in its report, so duplicates would make a failure
    /// ambiguous.
    func testSelectorNamesAreUnique() {
        let selectors = TeamsSelectors.flyoutSelectors + TeamsSelectors.editorSelectors
            + [TeamsSelectors.profileButton, TeamsSelectors.showWhenMessagedCheckbox]
        let names = selectors.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testEverySelectorDescribesItself() {
        let selectors = [TeamsSelectors.profileButton, TeamsSelectors.statusReadout,
                         TeamsSelectors.composeBox, TeamsSelectors.doneButton,
                         TeamsSelectors.clearAfterPopup, TeamsSelectors.showWhenMessagedCheckbox]
        for selector in selectors {
            XCTAssertFalse(selector.describedAs.isEmpty,
                           "\(selector.name) needs a description — it is what a bug report shows")
        }
    }

    func testNeverIsAValidClearDuration() {
        XCTAssertTrue(TeamsSelectors.clearAfterOptions.contains("Never"))
    }

    func testTeamsCharacterLimit() {
        XCTAssertEqual(TeamsSelectors.statusCharacterLimit, 280)
    }
}

final class AppStateTests: XCTestCase {

    /// The menu bar only prompts the user when there is something they can actually do.
    func testOnlyActionableStatesDemandUserAction() {
        XCTAssertTrue(AppState.spotifyDisconnected.needsUserAction)
        XCTAssertTrue(AppState.teamsAccessibilityPermissionMissing.needsUserAction)
        XCTAssertTrue(AppState.teamsSelectorsChanged("x").needsUserAction)
        XCTAssertTrue(AppState.spotifyAuthExpired.needsUserAction)

        XCTAssertFalse(AppState.ready.needsUserAction)
        XCTAssertFalse(AppState.noPlayback.needsUserAction)
        XCTAssertFalse(AppState.disabled.needsUserAction)
        // Transient problems resolve themselves; nagging about them would be wrong.
        XCTAssertFalse(AppState.spotifyRateLimited(until: Date()).needsUserAction)
        XCTAssertFalse(AppState.teamsNotRunning.needsUserAction)
        XCTAssertFalse(AppState.recovering.needsUserAction)
    }

    func testEveryStateHasANonEmptyTitle() {
        let states: [AppState] = [
            .disabled, .ready, .syncing, .noPlayback, .spotifyDisconnected,
            .spotifyAuthExpired, .spotifyPermissionMissing("x"),
            .spotifyRateLimited(until: Date()), .spotifyUnreachable("x"),
            .teamsNotRunning, .teamsAccessibilityPermissionMissing,
            .teamsAccessibilityTreeUnavailable, .teamsSelectorsChanged("x"),
            .manualOverrideDetected(nil), .recovering,
        ]
        for state in states {
            XCTAssertFalse(state.title.isEmpty, "\(state) has no title")
        }
    }

    func testManualOverrideNamesTheStatusTheUserSet() {
        let detail = AppState.manualOverrideDetected("In site meeting").detail
        XCTAssertEqual(detail?.contains("In site meeting"), true)
    }
}

final class PresenceSourceErrorTests: XCTestCase {

    func testTransientAndReauthorizationAreMutuallyExclusive() {
        let errors: [PresenceSourceError] = [
            .notAuthorized, .authorizationExpired, .permissionsMissing("x"),
            .rateLimited(retryAfter: 1), .network("x"),
            .serviceError(status: 500, message: nil), .appNotRunning,
            .automationPermissionDenied,
        ]
        for error in errors {
            XCTAssertFalse(error.isTransient && error.requiresReauthorization,
                           "\(error) cannot be both worth retrying and require re-auth")
            XCTAssertNotNil(error.errorDescription)
        }
    }
}

final class TrackPresenceTests: XCTestCase {

    func testIdentityPrefersTheTrackID() {
        let presence = TrackPresence(trackName: "A", artists: ["B"], isPlaying: true, trackID: "id-1")
        XCTAssertEqual(presence.identity, "id-1")
    }

    /// The local source can omit an id; identity must still distinguish tracks.
    func testIdentityFallsBackToNameAndArtists() {
        let a = TrackPresence(trackName: "A", artists: ["X"], isPlaying: true, trackID: nil)
        let b = TrackPresence(trackName: "A", artists: ["Y"], isPlaying: true, trackID: nil)
        XCTAssertNotEqual(a.identity, b.identity)
    }

    func testEmptyArtistsDoNotCrashRendering() {
        let presence = TrackPresence(trackName: "Untitled", artists: [], isPlaying: true, trackID: "x")
        XCTAssertEqual(presence.primaryArtist, "")
        XCTAssertEqual(StatusTemplate().render(presence), "♪ Untitled")
    }
}
