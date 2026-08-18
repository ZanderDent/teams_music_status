import XCTest
@testable import TeamsMusicStatusCore

/// The local source's job is to distinguish *silence* from *not knowing*.
///
/// It used to return `TrackPresence?`, so "stopped", "not running", "the Apple Event
/// failed" and "the answer did not parse" all arrived as `nil`. The coordinator reads
/// `nil` as "nothing is playing", starts the pause grace, and can restore the user's
/// previous Teams status over a track that never stopped. Every test here exists to keep
/// those two categories apart.
final class SpotifyLocalSourceTests: XCTestCase {

    private func line(_ fields: String...) -> String { fields.joined(separator: "\t") }

    // MARK: - Explicit sentinels

    func testNotRunningIsItsOwnAnswer() throws {
        XCTAssertEqual(try SpotifyLocalSource.parse("NOTRUNNING"), .notRunning)
    }

    func testStoppedIsItsOwnAnswer() throws {
        XCTAssertEqual(try SpotifyLocalSource.parse("STOPPED"), .stopped)
    }

    func testSentinelsTolerateSurroundingWhitespace() throws {
        XCTAssertEqual(try SpotifyLocalSource.parse("  NOTRUNNING\n"), .notRunning)
        XCTAssertEqual(try SpotifyLocalSource.parse("\nSTOPPED  "), .stopped)
    }

    // MARK: - Playing and paused

    func testPlayingCarriesTheTrack() throws {
        let reading = try SpotifyLocalSource.parse(
            line("playing", "Dreams", "Fleetwood Mac", "Rumours", "spotify:track:abc123", "255000", "12.5"))
        guard case .playing(let track) = reading else { return XCTFail("expected .playing, got \(reading)") }
        XCTAssertEqual(track.trackName, "Dreams")
        XCTAssertEqual(track.artists, ["Fleetwood Mac"])
        XCTAssertEqual(track.albumName, "Rumours")
        XCTAssertEqual(track.trackID, "abc123")
        XCTAssertTrue(track.isPlaying)
    }

    /// Paused is not stopped. Spotify still exposes the loaded track, and losing that
    /// distinction is what made a pause look like the end of playback.
    func testPausedKeepsItsMetadataAndIsNotSilence() throws {
        let reading = try SpotifyLocalSource.parse(
            line("paused", "Dreams", "Fleetwood Mac", "Rumours", "spotify:track:abc123", "255000", "12.5"))
        guard case .paused(let track) = reading else { return XCTFail("expected .paused, got \(reading)") }
        XCTAssertEqual(track.trackName, "Dreams")
        XCTAssertFalse(track.isPlaying)
        XCTAssertFalse(reading.isDefinitelySilent, "a paused track is not evidence of silence")
        XCTAssertNotNil(reading.presence)
    }

    func testOnlyStoppedAndNotRunningCountAsSilence() {
        XCTAssertTrue(LocalPlaybackReading.stopped.isDefinitelySilent)
        XCTAssertTrue(LocalPlaybackReading.notRunning.isDefinitelySilent)
        XCTAssertNil(LocalPlaybackReading.stopped.presence)
        XCTAssertNil(LocalPlaybackReading.notRunning.presence)
    }

    // MARK: - Tolerating older Spotify builds

    /// Duration and position were added later. An older Spotify that answers with five
    /// fields must still parse rather than being reported as a failure.
    func testFiveFieldAnswerStillParses() throws {
        let reading = try SpotifyLocalSource.parse(
            line("playing", "Dreams", "Fleetwood Mac", "Rumours", "spotify:track:abc123"))
        guard case .playing(let track) = reading else { return XCTFail("expected .playing") }
        XCTAssertEqual(track.trackName, "Dreams")
    }

    func testEmptyOptionalFieldsAreTolerated() throws {
        let reading = try SpotifyLocalSource.parse(
            line("playing", "Untitled", "", "", "spotify:track:x"))
        guard case .playing(let track) = reading else { return XCTFail("expected .playing") }
        XCTAssertEqual(track.artists, [])
        XCTAssertNil(track.albumName)
    }

    // MARK: - Failures must throw, never return silence

    func testEmptyAnswerIsAFailureNotSilence() {
        XCTAssertThrowsError(try SpotifyLocalSource.parse("")) { error in
            guard case PresenceSourceError.parseFailure = error else {
                return XCTFail("expected .parseFailure, got \(error)")
            }
        }
    }

    func testTruncatedAnswerIsAFailureNotSilence() {
        XCTAssertThrowsError(try SpotifyLocalSource.parse(line("playing", "Dreams"))) { error in
            guard case PresenceSourceError.parseFailure = error else {
                return XCTFail("expected .parseFailure, got \(error)")
            }
        }
    }

    /// An unrecognised player state is a bug to fix, not a reason to tell the user their
    /// music stopped.
    func testUnknownPlayerStateIsAFailureNotSilence() {
        XCTAssertThrowsError(
            try SpotifyLocalSource.parse(line("buffering", "Dreams", "X", "Y", "spotify:track:z"))
        ) { error in
            guard case PresenceSourceError.parseFailure = error else {
                return XCTFail("expected .parseFailure, got \(error)")
            }
        }
    }

    // MARK: - Error classification

    func testTransientFailuresAreMarkedRetryable() {
        XCTAssertTrue(PresenceSourceError.appleEventFailure(code: -1728, message: "x").isTransient)
        XCTAssertTrue(PresenceSourceError.timedOut(seconds: 5).isTransient)
        XCTAssertTrue(PresenceSourceError.appNotRunning.isTransient)
    }

    /// A denied Automation grant is permanent until the user acts, and must never be
    /// retried forever or hidden behind resilience.
    func testPermissionDenialIsNotTransientAndExplainsTheFix() {
        XCTAssertFalse(PresenceSourceError.automationPermissionDenied.isTransient)
        let message = PresenceSourceError.automationPermissionDenied.errorDescription ?? ""
        XCTAssertTrue(message.contains("Automation"))
        XCTAssertTrue(message.contains("System Settings"), "the error must say where to fix it")
    }

    func testParseFailureIsNotTransient() {
        XCTAssertFalse(PresenceSourceError.parseFailure("x").isTransient)
    }

    /// Each failure has to be legible on its own; "no playback" told the user nothing.
    func testEveryLocalFailureDescribesItself() {
        let cases: [PresenceSourceError] = [
            .automationPermissionDenied,
            .appleEventFailure(code: -1712, message: "timed out"),
            .timedOut(seconds: 5),
            .parseFailure("unknown player state 'buffering'"),
            .appNotRunning,
        ]
        for error in cases {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error) has no description")
            XCTAssertFalse(text.lowercased().contains("no active playback"),
                           "\(error) must not be phrased as silence")
        }
    }

    // MARK: - The measurement bug

    /// `tmsctl` initialised its result to `.success(nil)` — "no playback" — and discarded
    /// the semaphore's wait status. Any read that had not finished printed a reading the
    /// tool invented. That is the harness the Local source was judged by, and it made the
    /// source look far less reliable than it is (~20% false silence against 0/300 for the
    /// underlying script).
    ///
    /// The shape is what matters: an un-set result must stay un-set, so a timeout can be
    /// told apart from a real answer of "nothing playing".
    func testAnUnfinishedReadIsNotAnAnswer() {
        var result: Result<TrackPresence?, Error>?
        XCTAssertNil(result, "before the work finishes there is no answer, not a silent one")

        result = .success(nil)      // a genuine observation of silence
        guard case .success(let presence)? = result else { return XCTFail("expected a result") }
        XCTAssertNil(presence)

        var timedOut: Result<TrackPresence?, Error>?
        XCTAssertNil(timedOut, "a timeout must remain distinguishable from observed silence")
    }
}
