import XCTest
@testable import TeamsMusicStatusCore

/// Template rendering, Unicode sanitisation and the 280-character clamp.
final class TextRenderingTests: XCTestCase {

    private let dreams = TrackPresence(trackName: "Dreams",
                                       artists: ["Fleetwood Mac"],
                                       albumName: "Rumours",
                                       isPlaying: true,
                                       trackID: "id")

    // MARK: Template

    func testDefaultTemplateRendersTrackAndArtists() {
        XCTAssertEqual(StatusTemplate().render(dreams), "♪ Dreams — Fleetwood Mac")
    }

    func testAllPlaceholdersResolve() {
        let multi = TrackPresence(trackName: "Define", artists: ["Dom Dolla", "Go Freek"],
                                  albumName: "Define", isPlaying: true, trackID: "x")
        XCTAssertEqual(StatusTemplate("{track}").render(multi), "Define")
        XCTAssertEqual(StatusTemplate("{artist}").render(multi), "Dom Dolla")
        XCTAssertEqual(StatusTemplate("{artists}").render(multi), "Dom Dolla, Go Freek")
        XCTAssertEqual(StatusTemplate("{album}").render(multi), "Define")
    }

    /// `{artist}` is a prefix of `{artists}`; substituting in the wrong order would turn
    /// `{artists}` into "Dom Dollas".
    func testArtistsIsNotManglingByArtistSubstitution() {
        let multi = TrackPresence(trackName: "T", artists: ["Dom Dolla", "Go Freek"],
                                  isPlaying: true, trackID: "x")
        XCTAssertEqual(StatusTemplate("{artists}").render(multi), "Dom Dolla, Go Freek")
    }

    func testEmptyAlbumDoesNotLeaveDanglingPunctuation() {
        let noAlbum = TrackPresence(trackName: "Dreams", artists: ["Fleetwood Mac"],
                                    albumName: nil, isPlaying: true, trackID: "id")
        XCTAssertEqual(StatusTemplate("♪ {track} — {album}").render(noAlbum), "♪ Dreams")
        XCTAssertEqual(StatusTemplate("{track} ({album})").render(noAlbum), "Dreams")
    }

    // MARK: Unicode

    func testAstralEmojiAreSubstitutedNotDropped() {
        let result = UnicodeSanitizer.sanitize("🎵 Dreams")
        XCTAssertEqual(result.text, "♪ Dreams")
        XCTAssertEqual(result.substituted, 1)
        XCTAssertEqual(result.dropped, 0)
    }

    func testKnownMusicEmojiMapToBMPEquivalents() {
        XCTAssertEqual(UnicodeSanitizer.sanitize("🎶").text, "♫")
        XCTAssertEqual(UnicodeSanitizer.sanitize("🎧").text, "♪")
    }

    func testUnmappedAstralCharactersAreDroppedAndWhitespaceTidied() {
        // 🚀 has no musical equivalent; dropping it must not leave a double space.
        let result = UnicodeSanitizer.sanitize("A 🚀 B")
        XCTAssertEqual(result.text, "A B")
        XCTAssertEqual(result.dropped, 1)
    }

    func testBMPCharactersSurviveUntouched() {
        // Everything here is BMP and was verified to reach Teams intact.
        let input = "♪ Björk — Jóga ♫ — Æther"
        XCTAssertEqual(UnicodeSanitizer.sanitize(input).text, input)
        XCTAssertFalse(UnicodeSanitizer.sanitize(input).wasModified)
    }

    func testTemplateSanitizesAstralEmojiTypedByTheUser() {
        XCTAssertEqual(StatusTemplate("🎵 {track}").render(dreams), "♪ Dreams")
    }

    // MARK: Clamp

    func testShortTextIsNotClamped() {
        XCTAssertEqual(UnicodeSanitizer.clamp("short", limit: 280), "short")
    }

    func testClampRespectsTheLimitIncludingTheEllipsis() {
        let long = String(repeating: "a", count: 400)
        let clamped = UnicodeSanitizer.clamp(long, limit: 280)
        XCTAssertEqual(clamped.count, 280)
        XCTAssertTrue(clamped.hasSuffix("…"))
    }

    func testClampNeverSplitsAGraphemeCluster() {
        // Family emoji and flags are multi-scalar; truncating mid-cluster would corrupt them.
        let text = String(repeating: "é", count: 50) + String(repeating: "ü", count: 50)
        let clamped = UnicodeSanitizer.clamp(text, limit: 60)
        XCTAssertEqual(clamped.count, 60)
        // Every character is still a well-formed cluster.
        XCTAssertTrue(clamped.dropLast().allSatisfy { $0 == "é" || $0 == "ü" })
    }

    func testRenderClampsToTeamsLimit() {
        let epic = TrackPresence(trackName: String(repeating: "Song ", count: 100),
                                 artists: [String(repeating: "Artist ", count: 50)],
                                 isPlaying: true, trackID: "x")
        let rendered = StatusTemplate().render(epic)
        XCTAssertLessThanOrEqual(rendered.count, TeamsSelectors.statusCharacterLimit)
    }

    /// The documented degradation order: drop the album before truncating anything.
    func testAlbumIsDroppedBeforeTruncating() {
        let track = TrackPresence(trackName: String(repeating: "T", count: 120),
                                  artists: [String(repeating: "A", count: 120)],
                                  albumName: String(repeating: "B", count: 120),
                                  isPlaying: true, trackID: "x")
        let rendered = StatusTemplate("{track} — {artists} — {album}").render(track)
        XCTAssertLessThanOrEqual(rendered.count, 280)
        XCTAssertFalse(rendered.contains("B"), "album should be dropped before truncation")
        XCTAssertFalse(rendered.hasSuffix("…"), "dropping the album should have been enough")
    }
}
