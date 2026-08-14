import XCTest
@testable import TeamsMusicStatusCore

/// Regression tests for the restart defect found in acceptance testing.
final class RestoreStateStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RestoreStateStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> RestoreStateStore { RestoreStateStore(defaults: defaults) }

    func testNothingIsRememberedInitially() {
        var state = SyncEngine.State()
        store().load(into: &state)
        XCTAssertNil(state.lastWrittenByApp)
        XCTAssertNil(state.savedUserStatus)
    }

    func testWrittenStatusAndOriginalSurviveARoundTrip() {
        var state = SyncEngine.State()
        SyncEngine.recordWrite(state: &state, status: "♪ A", previousTeamsStatus: "In the office")
        store().save(from: state)

        var reloaded = SyncEngine.State()
        store().load(into: &reloaded)
        XCTAssertEqual(reloaded.lastWrittenByApp, "♪ A")
        XCTAssertEqual(reloaded.savedUserStatus, .some("In the office"))
    }

    /// "The user had no status" must survive as `.some(nil)`, not collapse to "unknown".
    /// Getting this wrong would restore some earlier guess instead of clearing.
    func testAnEmptyOriginalIsDistinctFromNeverCaptured() {
        var state = SyncEngine.State()
        SyncEngine.recordWrite(state: &state, status: "♪ A", previousTeamsStatus: nil)
        store().save(from: state)

        var reloaded = SyncEngine.State()
        store().load(into: &reloaded)
        XCTAssertEqual(reloaded.savedUserStatus, .some(nil))
        XCTAssertNotNil(reloaded.savedUserStatus, "captured-but-empty must not read as never-captured")

        XCTAssertEqual(SyncEngine.disableAction(state: reloaded, currentTeamsStatus: "♪ A"),
                       .restore(nil))
    }

    func testClearForgetsEverything() {
        var state = SyncEngine.State()
        SyncEngine.recordWrite(state: &state, status: "♪ A", previousTeamsStatus: "Original")
        let store = store()
        store.save(from: state)
        store.clear()

        var reloaded = SyncEngine.State()
        store.load(into: &reloaded)
        XCTAssertNil(reloaded.lastWrittenByApp)
        XCTAssertNil(reloaded.savedUserStatus)
    }

    /// The actual defect: the app wrote a status, was relaunched, and captured its OWN
    /// leftover status as the user's original. Repeat that and the real status is lost.
    func testRelaunchDoesNotAdoptOurOwnStatusAsTheUsersOriginal() {
        // First run: user had "Listening to: House"; the app writes over it.
        var firstRun = SyncEngine.State()
        SyncEngine.recordWrite(state: &firstRun, status: "♪ Blow my mind by kage",
                               previousTeamsStatus: "Listening to: House")
        store().save(from: firstRun)

        // Relaunch. Teams still shows what the app wrote.
        var secondRun = SyncEngine.State()
        store().load(into: &secondRun)

        // A new write must NOT recapture the baseline, because one is already known.
        SyncEngine.recordWrite(state: &secondRun, status: "♪ catharsis by oklou",
                               previousTeamsStatus: "♪ Blow my mind by kage")

        XCTAssertEqual(secondRun.savedUserStatus, .some("Listening to: House"),
                       "the user's real status must survive a relaunch")
        XCTAssertEqual(SyncEngine.disableAction(state: secondRun,
                                                currentTeamsStatus: "♪ catharsis by oklou"),
                       .restore("Listening to: House"))
    }

    /// The persisted value must never cause an overwrite: if the user changed their status
    /// between launches, that is a manual override, not something to restore over.
    func testPersistedOwnershipStillYieldsToAManualEdit() {
        var firstRun = SyncEngine.State()
        SyncEngine.recordWrite(state: &firstRun, status: "♪ A", previousTeamsStatus: "Original")
        store().save(from: firstRun)

        var secondRun = SyncEngine.State()
        store().load(into: &secondRun)

        let engine = SyncEngine()
        let presence = TrackPresence(trackName: "B", artists: ["X"], isPlaying: true, trackID: "b")
        let action = engine.step(
            state: &secondRun,
            input: .init(presence: presence,
                         rendered: "♪ B by X",
                         observedTeamsStatus: .some("In site meeting")),
            now: Date())

        XCTAssertEqual(action, .reportManualOverride(found: "In site meeting"))
        XCTAssertEqual(SyncEngine.disableAction(state: secondRun,
                                                currentTeamsStatus: "In site meeting"),
                       .doNothing)
    }
}
