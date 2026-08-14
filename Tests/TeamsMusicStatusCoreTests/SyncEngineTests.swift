import XCTest
@testable import TeamsMusicStatusCore

/// The behavioural contract of the integration: debounce, pause grace, restore, and the
/// rule that the user always wins a fight over their own status.
final class SyncEngineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func playing(_ name: String = "Dreams",
                         artists: [String] = ["Fleetwood Mac"],
                         id: String = "track-1") -> TrackPresence {
        TrackPresence(trackName: name, artists: artists, albumName: "Rumours",
                      isPlaying: true, trackID: id)
    }

    private func input(_ presence: TrackPresence?,
                       observed: String?? = nil) -> SyncEngine.Input {
        SyncEngine.Input(presence: presence,
                         rendered: presence.map { StatusTemplate().render($0) },
                         observedTeamsStatus: observed)
    }

    // MARK: Debounce

    func testWriteIsHeldBackUntilTheCandidateIsStable() {
        let engine = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 300))
        var state = SyncEngine.State()
        let track = playing()

        // First sighting only arms the debounce.
        XCTAssertEqual(engine.step(state: &state, input: input(track), now: t0), .doNothing)
        // Still inside the window.
        XCTAssertEqual(engine.step(state: &state, input: input(track), now: t0 + 4), .doNothing)
        // Window elapsed.
        XCTAssertEqual(engine.step(state: &state, input: input(track), now: t0 + 5),
                       .write("♪ Dreams by Fleetwood Mac"))
    }

    func testSkippingTracksProducesOneWriteNotMany() {
        let engine = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 300))
        var state = SyncEngine.State()

        // Four rapid skips, each one second apart — the debounce restarts every time.
        for (index, second) in [0.0, 1, 2, 3].enumerated() {
            let action = engine.step(state: &state,
                                     input: input(playing("Track \(index)", id: "id-\(index)")),
                                     now: t0 + second)
            XCTAssertEqual(action, .doNothing, "skip \(index) should not write")
        }
        // Settling on the last one still requires a full quiet window.
        let settled = playing("Track 3", id: "id-3")
        XCTAssertEqual(engine.step(state: &state, input: input(settled), now: t0 + 4), .doNothing)
        XCTAssertEqual(engine.step(state: &state, input: input(settled), now: t0 + 9),
                       .write("♪ Track 3 by Fleetwood Mac"))
    }

    func testUnchangedStatusIsNeverRewritten() {
        let engine = SyncEngine()
        var state = SyncEngine.State()
        state.lastWrittenByApp = "♪ Dreams by Fleetwood Mac"

        XCTAssertEqual(engine.step(state: &state, input: input(playing()), now: t0), .doNothing)
        XCTAssertEqual(engine.step(state: &state, input: input(playing()), now: t0 + 60), .doNothing)
    }

    // MARK: Pause grace

    func testPauseInsideGracePeriodChangesNothing() {
        let engine = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 300))
        var state = SyncEngine.State()
        state.lastWrittenByApp = "♪ Dreams by Fleetwood Mac"
        state.savedUserStatus = .some("In the office")

        let paused = TrackPresence(trackName: "Dreams", artists: ["Fleetwood Mac"],
                                   isPlaying: false, trackID: "track-1")
        XCTAssertEqual(engine.step(state: &state, input: input(paused), now: t0), .doNothing)
        XCTAssertEqual(engine.step(state: &state, input: input(paused), now: t0 + 299), .doNothing)
    }

    func testPauseBeyondGracePeriodRestoresThePreviousStatus() {
        let engine = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 300))
        var state = SyncEngine.State()
        state.lastWrittenByApp = "♪ Dreams by Fleetwood Mac"
        state.savedUserStatus = .some("In the office")

        let paused = TrackPresence(trackName: "Dreams", artists: ["Fleetwood Mac"],
                                   isPlaying: false, trackID: "track-1")
        _ = engine.step(state: &state, input: input(paused), now: t0)
        XCTAssertEqual(engine.step(state: &state, input: input(paused), now: t0 + 300),
                       .restore("In the office"))
        XCTAssertNil(state.lastWrittenByApp, "restoring clears what we believe Teams shows")
    }

    func testResumingInsideGraceCausesNoChurn() {
        let engine = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 300))
        var state = SyncEngine.State()
        let track = playing()
        state.lastWrittenByApp = StatusTemplate().render(track)

        let paused = TrackPresence(trackName: "Dreams", artists: ["Fleetwood Mac"],
                                   isPlaying: false, trackID: "track-1")
        _ = engine.step(state: &state, input: input(paused), now: t0)
        // Resume with the same track: nothing to write, and the idle timer resets.
        XCTAssertEqual(engine.step(state: &state, input: input(track), now: t0 + 30), .doNothing)
        XCTAssertNil(state.idleSince)
    }

    func testNoPlaybackRestoresAfterGrace() {
        let engine = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 60))
        var state = SyncEngine.State()
        state.lastWrittenByApp = "♪ Dreams by Fleetwood Mac"
        state.savedUserStatus = .some(nil)   // user had no status before

        _ = engine.step(state: &state, input: input(nil), now: t0)
        XCTAssertEqual(engine.step(state: &state, input: input(nil), now: t0 + 60), .restore(nil))
    }

    func testNothingIsRestoredIfNothingWasEverWritten() {
        let engine = SyncEngine(configuration: .init(debounce: 5, pauseGrace: 1))
        var state = SyncEngine.State()
        XCTAssertEqual(engine.step(state: &state, input: input(nil), now: t0), .doNothing)
        XCTAssertEqual(engine.step(state: &state, input: input(nil), now: t0 + 999), .doNothing)
    }

    // MARK: Manual override

    func testManualEditIsDetectedAndStopsFurtherWrites() {
        let engine = SyncEngine()
        var state = SyncEngine.State()
        state.lastWrittenByApp = "♪ Dreams by Fleetwood Mac"

        let action = engine.step(state: &state,
                                 input: input(playing(), observed: .some("In site meeting")),
                                 now: t0)
        XCTAssertEqual(action, .reportManualOverride(found: "In site meeting"))
        XCTAssertTrue(state.manualOverrideDetected)

        // Latched: even a fresh track does not resume writing.
        let next = engine.step(state: &state,
                               input: input(playing("Rhiannon", id: "track-2")),
                               now: t0 + 600)
        XCTAssertEqual(next, .doNothing)
    }

    func testNotObservingTeamsIsNotTreatedAsAnEmptyStatus() {
        let engine = SyncEngine()
        var state = SyncEngine.State()
        state.lastWrittenByApp = "♪ Dreams by Fleetwood Mac"

        // observed == nil means "we did not look", which must not read as an override.
        let action = engine.step(state: &state, input: input(playing(), observed: nil), now: t0)
        XCTAssertEqual(action, .doNothing)
        XCTAssertFalse(state.manualOverrideDetected)
    }

    func testStatusMatchingWhatWeWroteIsNotAnOverride() {
        let engine = SyncEngine()
        var state = SyncEngine.State()
        state.lastWrittenByApp = "♪ Dreams by Fleetwood Mac"

        let action = engine.step(state: &state,
                                 input: input(playing(), observed: .some("♪ Dreams by Fleetwood Mac")),
                                 now: t0)
        XCTAssertEqual(action, .doNothing)
        XCTAssertFalse(state.manualOverrideDetected)
    }

    func testUserStatusBeforeWeWriteAnythingIsNotAnOverride() {
        let engine = SyncEngine()
        var state = SyncEngine.State()   // lastWrittenByApp == nil

        let action = engine.step(state: &state,
                                 input: input(playing(), observed: .some("Heads down")),
                                 now: t0)
        XCTAssertEqual(action, .doNothing)
        XCTAssertFalse(state.manualOverrideDetected)
    }

    // MARK: Save / restore

    func testFirstWriteCapturesTheUsersOriginalStatus() {
        var state = SyncEngine.State()
        SyncEngine.recordWrite(state: &state, status: "♪ A", previousTeamsStatus: "In the office")
        XCTAssertEqual(state.savedUserStatus, .some("In the office"))

        // A later write must not clobber the captured original.
        SyncEngine.recordWrite(state: &state, status: "♪ B", previousTeamsStatus: "♪ A")
        XCTAssertEqual(state.savedUserStatus, .some("In the office"))
        XCTAssertEqual(state.lastWrittenByApp, "♪ B")
    }

    func testDisableRestoresWhenTeamsStillShowsOurStatus() {
        var state = SyncEngine.State()
        SyncEngine.recordWrite(state: &state, status: "♪ A", previousTeamsStatus: "In the office")

        XCTAssertEqual(SyncEngine.disableAction(state: state, currentTeamsStatus: "♪ A"),
                       .restore("In the office"))
    }

    /// The scenario from the brief: the app set a status, the user replaced it by hand,
    /// then disabled the integration. Their text must survive.
    func testDisableKeepsAStatusTheUserTypedThemselves() {
        var state = SyncEngine.State()
        SyncEngine.recordWrite(state: &state, status: "♪ Dreams by Fleetwood Mac",
                               previousTeamsStatus: "Old status")

        XCTAssertEqual(SyncEngine.disableAction(state: state,
                                                currentTeamsStatus: "In site meeting"),
                       .doNothing)
    }

    func testDisableDoesNothingIfWeNeverWrote() {
        let state = SyncEngine.State()
        XCTAssertEqual(SyncEngine.disableAction(state: state, currentTeamsStatus: "Anything"),
                       .doNothing)
    }

    func testRestoringToAnEmptyOriginalClearsTheStatus() {
        var state = SyncEngine.State()
        SyncEngine.recordWrite(state: &state, status: "♪ A", previousTeamsStatus: nil)
        XCTAssertEqual(SyncEngine.disableAction(state: state, currentTeamsStatus: "♪ A"),
                       .restore(nil))
    }
}
