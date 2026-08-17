import XCTest
@testable import TeamsMusicStatusCore

/// Writing a status types into the Teams flyout. Doing that while the user is typing in
/// Teams themselves risks stealing their keystrokes, so writes wait for them to leave —
/// capped, so someone who lives in Teams still gets status updates.
///
/// Input is never blocked. The user is never prevented from doing anything; the app
/// simply picks a better moment.
final class WriteDeferralTests: XCTestCase {

    private let track = TrackPresence(
        trackName: "Dreams", artists: ["Fleetwood Mac"], albumName: "Rumours",
        isPlaying: true, trackID: "t1"
    )
    private var rendered: String { StatusTemplate().render(track) }
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func engine(cap: TimeInterval = 30) -> SyncEngine {
        SyncEngine(configuration: .init(debounce: 5, pauseGrace: 300, frontmostDeferCap: cap))
    }

    private func input(_ interaction: SyncEngine.TeamsInteraction) -> SyncEngine.Input {
        SyncEngine.Input(presence: track, rendered: rendered,
                         observedTeamsStatus: nil, teamsInteraction: interaction)
    }

    // MARK: - Teams in the background: unchanged behaviour

    func testWritesImmediatelyWhenTeamsIsInTheBackground() {
        var state = SyncEngine.State()
        let action = engine().step(state: &state, input: input(.available), now: start)
        XCTAssertEqual(action, .write(rendered))
    }

    // MARK: - User is in Teams

    func testDefersWhileTheUserIsWorkingInTeams() {
        var state = SyncEngine.State()
        let action = engine().step(state: &state, input: input(.userIsInTeams), now: start)
        XCTAssertEqual(action, .doNothing, "must not type into Teams while the user is in it")
        XCTAssertEqual(state.deferredSince, start, "the clock starts when the write is wanted")
    }

    func testWritesAsSoonAsTheUserLeavesTeams() {
        var state = SyncEngine.State()
        let sync = engine()
        XCTAssertEqual(sync.step(state: &state, input: input(.userIsInTeams), now: start), .doNothing)

        let left = start.addingTimeInterval(4)
        XCTAssertEqual(sync.step(state: &state, input: input(.available), now: left), .write(rendered),
                       "no reason to keep waiting once they have gone")
        XCTAssertNil(state.deferredSince)
    }

    func testWritesAnywayOnceTheCapElapses() {
        var state = SyncEngine.State()
        let sync = engine(cap: 30)

        XCTAssertEqual(sync.step(state: &state, input: input(.userIsInTeams), now: start), .doNothing)
        XCTAssertEqual(sync.step(state: &state, input: input(.userIsInTeams),
                                 now: start.addingTimeInterval(29)), .doNothing)
        XCTAssertEqual(sync.step(state: &state, input: input(.userIsInTeams),
                                 now: start.addingTimeInterval(30)), .write(rendered),
                       "someone who lives in Teams must still get status updates")
        XCTAssertNil(state.deferredSince, "the clock resets once the write goes through")
    }

    /// The clock must run from when a write became *wanted*, not from when Teams came to
    /// the front. Otherwise sitting in Teams for five minutes means the next track change
    /// writes instantly — precisely the collision the deferral exists to prevent.
    func testTheClockStartsWhenTheWriteIsWantedNotWhenTeamsComesForward() {
        var state = SyncEngine.State()
        let sync = engine()

        // Ten minutes in Teams with the status already correct: nothing is pending.
        state.lastWrittenByApp = rendered
        for minute in 0..<10 {
            let now = start.addingTimeInterval(Double(minute) * 60)
            XCTAssertEqual(sync.step(state: &state, input: input(.userIsInTeams), now: now), .doNothing)
            XCTAssertNil(state.deferredSince, "nothing is being held back, so no clock")
        }

        // Now the track changes while they are still in Teams.
        let newTrack = TrackPresence(trackName: "The Chain", artists: ["Fleetwood Mac"],
                                     albumName: "Rumours", isPlaying: true, trackID: "t2")
        let newRendered = StatusTemplate().render(newTrack)
        let changed = start.addingTimeInterval(600)
        let newInput = SyncEngine.Input(presence: newTrack, rendered: newRendered,
                                        observedTeamsStatus: nil, teamsInteraction: .userIsInTeams)
        XCTAssertEqual(sync.step(state: &state, input: newInput, now: changed), .doNothing,
                       "must defer, not fire instantly because Teams has been front for ages")
        XCTAssertEqual(state.deferredSince, changed)
    }

    // MARK: - Sign-in: indefinite, no exceptions

    func testNeverTouchesTeamsWhileItIsAskingForSignIn() {
        var state = SyncEngine.State()
        let sync = engine()
        // Far longer than the frontmost cap: sign-in has no cap at all.
        for offset in [0.0, 30.0, 120.0, 3600.0, 86_400.0] {
            let action = sync.step(state: &state, input: input(.signInRequired),
                                   now: start.addingTimeInterval(offset))
            XCTAssertEqual(action, .doNothing, "still must not touch Teams after \(offset)s")
        }
    }

    func testResumesNormallyOnceSignInIsDone() {
        var state = SyncEngine.State()
        let sync = engine()
        _ = sync.step(state: &state, input: input(.signInRequired), now: start)
        let after = start.addingTimeInterval(120)
        XCTAssertEqual(sync.step(state: &state, input: input(.available), now: after), .write(rendered))
    }

    // MARK: - Deferring must not corrupt state

    /// `decide` mutates state assuming its action is carried out — `.restore` clears
    /// `lastWrittenByApp`, writes clear the pending candidate. Committing those while
    /// suppressing the action would silently lose the user's saved status, so a deferred
    /// decision has to leave state alone.
    func testDeferringARestoreDoesNotDiscardTheUsersSavedStatus() {
        var state = SyncEngine.State()
        state.lastWrittenByApp = rendered
        state.savedUserStatus = .some("In a meeting")
        state.idleSince = start.addingTimeInterval(-400)   // grace already elapsed

        let paused = SyncEngine.Input(presence: nil, rendered: nil,
                                      observedTeamsStatus: nil, teamsInteraction: .userIsInTeams)
        let sync = engine()

        XCTAssertEqual(sync.step(state: &state, input: paused, now: start), .doNothing)
        XCTAssertEqual(state.lastWrittenByApp, rendered, "ownership must survive the deferral")
        XCTAssertEqual(state.savedUserStatus, .some("In a meeting"),
                       "the status to restore must not be thrown away")

        // Once they leave Teams, the restore still happens with the right value.
        let after = start.addingTimeInterval(1)
        let resumed = SyncEngine.Input(presence: nil, rendered: nil,
                                       observedTeamsStatus: nil, teamsInteraction: .available)
        XCTAssertEqual(sync.step(state: &state, input: resumed, now: after), .restore("In a meeting"))
    }

    func testDeferringAWriteDoesNotMarkItAsWritten() {
        var state = SyncEngine.State()
        let sync = engine()
        _ = sync.step(state: &state, input: input(.userIsInTeams), now: start)
        XCTAssertNil(state.lastWrittenByApp, "nothing was written, so nothing may be recorded")
        XCTAssertNil(state.lastWriteAt)
    }

    // MARK: - Only Teams-touching actions are deferred

    func testManualOverrideIsStillReportedWhileTheUserIsInTeams() {
        var state = SyncEngine.State()
        state.lastWrittenByApp = rendered
        let observed = SyncEngine.Input(presence: track, rendered: rendered,
                                        observedTeamsStatus: .some("Heads down"),
                                        teamsInteraction: .userIsInTeams)
        // Reporting an override changes no Teams UI, so there is nothing to defer — and
        // suppressing it would leave the user wondering why nothing updates.
        XCTAssertEqual(engine().step(state: &state, input: observed, now: start),
                       .reportManualOverride(found: "Heads down"))
    }
}

// MARK: - Minimized Teams

extension WriteDeferralTests {

    private var minimisedInput: SyncEngine.Input {
        SyncEngine.Input(presence: TrackPresence(trackName: "Dreams", artists: ["Fleetwood Mac"],
                                                 albumName: "Rumours", isPlaying: true, trackID: "t1"),
                         rendered: StatusTemplate().render(StatusTemplate.previewPresence),
                         observedTeamsStatus: nil,
                         teamsInteraction: .minimized)
    }

    /// Chromium will not run click handlers for a minimized window, so writing means
    /// restoring it — which throws Teams in front of whatever the user is doing, and never
    /// puts it back. Measured: the window went to z-index 0 and stayed un-minimized.
    /// Waiting is strictly better than yanking someone's window out of the Dock.
    func testNeverRestoresAMinimizedTeamsJustToWrite() {
        var state = SyncEngine.State()
        let sync = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 300, frontmostDeferCap: 30))
        // Far past the frontmost cap: being minimized has no cap, like sign-in.
        for offset in [0.0, 30.0, 300.0, 3600.0] {
            let now = Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(offset)
            XCTAssertEqual(sync.step(state: &state, input: minimisedInput, now: now), .doNothing,
                           "must not restore the window after \(offset)s")
        }
        XCTAssertNil(state.lastWrittenByApp, "nothing was written")
    }

    func testResumesWhenTheUserOpensTeamsAgain() {
        var state = SyncEngine.State()
        let sync = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 300, frontmostDeferCap: 30))
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(sync.step(state: &state, input: minimisedInput, now: start), .doNothing)

        let restored = SyncEngine.Input(presence: minimisedInput.presence,
                                        rendered: minimisedInput.rendered,
                                        observedTeamsStatus: nil,
                                        teamsInteraction: .available)
        guard case .write = sync.step(state: &state, input: restored,
                                      now: start.addingTimeInterval(5)) else {
            return XCTFail("should write as soon as Teams is usable again")
        }
    }
}
