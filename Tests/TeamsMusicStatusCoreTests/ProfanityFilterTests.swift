import XCTest
@testable import TeamsMusicStatusCore

/// The interesting half of these tests is the false positives. Masking a rude word is
/// easy; not mangling "Scunthorpe", "Sussex" or "assassin" is the part that goes wrong.
final class ProfanityFilterTests: XCTestCase {

    // MARK: - Masking

    func testMasksKeepingFirstAndLastCharacter() {
        XCTAssertEqual(ProfanityFilter.mask("fuck"), "f**k")
        XCTAssertEqual(ProfanityFilter.mask("shit"), "s**t")
        XCTAssertEqual(ProfanityFilter.mask("bitch"), "b***h")
        XCTAssertEqual(ProfanityFilter.mask("motherfucker"), "m**********r")
    }

    /// Mild words are deliberately not masked: the false positives cost more than the
    /// offence avoided. If someone adds these to the list, these titles break.
    func testMildWordsAreDeliberatelyNotMasked() {
        XCTAssertEqual(ProfanityFilter.mask("DAMN."), "DAMN.")
        XCTAssertEqual(ProfanityFilter.mask("Moby Dick"), "Moby Dick")
        XCTAssertEqual(ProfanityFilter.mask("Cock Robin"), "Cock Robin")
        XCTAssertEqual(ProfanityFilter.mask("Crap Shoot"), "Crap Shoot")
    }

    func testPreservesCasing() {
        XCTAssertEqual(ProfanityFilter.mask("Fuck"), "F**k")
        XCTAssertEqual(ProfanityFilter.mask("FUCK"), "F**K")
        XCTAssertEqual(ProfanityFilter.mask("FuCk"), "F**k")
    }

    func testMasksWithinASentence() {
        XCTAssertEqual(ProfanityFilter.mask("Thank Fuck It's The Weekend"),
                       "Thank F**k It's The Weekend")
    }

    func testMasksEveryOccurrence() {
        XCTAssertEqual(ProfanityFilter.mask("shit, shit and more shit"),
                       "s**t, s**t and more s**t")
    }

    func testPrefersTheLongestMatch() {
        // "motherfucking" must be masked as one word, not left as "mother" + a masked tail.
        XCTAssertEqual(ProfanityFilter.mask("motherfucking"), "m***********g")
    }

    func testMaskingIsIdempotent() {
        // A title that already ships masked must not be masked again into nonsense.
        let once = ProfanityFilter.mask("Fuck It")
        XCTAssertEqual(ProfanityFilter.mask(once), once)
    }

    func testPunctuationAndHyphensAreWordBoundaries() {
        XCTAssertEqual(ProfanityFilter.mask("(Fuck)"), "(F**k)")
        XCTAssertEqual(ProfanityFilter.mask("fuck-you"), "f**k-you")
        XCTAssertEqual(ProfanityFilter.mask("Shit!"), "S**t!")
    }

    // MARK: - The Scunthorpe problem

    /// Substring matching would destroy every one of these. They are real place names,
    /// real words and real artists, and getting one wrong is a visible bug on a work
    /// profile — a mangled title is confusing in a way the original never was.
    func testDoesNotMatchInnocentWordsContainingProfanity() {
        let innocent = [
            "Scunthorpe",           // the canonical case
            "Penistone",
            "Sussex",
            "assassin",
            "Assassin's Creed",
            "class",
            "classic",
            "Cassandra",
            "bass",
            "grass",
            "massive",
            "shiitake",
            "Dickinson",
            "cockatoo",
            "Cocteau Twins",
            "Hancock",
            "peacock",
            "titmouse",
            "Mississippi",
            "analysis",
            "Arsenal",
            "sassafras",
            "Cumbria",
            "accumulate",
            "circumstance",
        ]
        for word in innocent {
            XCTAssertEqual(ProfanityFilter.mask(word), word,
                           "\(word) must not be altered")
        }
    }

    func testDoesNotMatchAcrossWordBoundaries() {
        // "Grass Hopper" contains "ass" spanning nothing, but "Big Ass Truck" contains it
        // as a whole word. Only the standalone word is a candidate, and "ass" is
        // deliberately not on the list precisely because it is too collision-prone.
        XCTAssertEqual(ProfanityFilter.mask("Big Ass Truck"), "Big Ass Truck")
        XCTAssertEqual(ProfanityFilter.mask("Grass Hopper"), "Grass Hopper")
    }

    func testInnocentTracksSurviveUnchanged() {
        let titles = [
            "Dreams",
            "Bohemian Rhapsody",
            "Sussex Downs at Dawn",
            "Classical Gas",
            "The Assassination of Jesse James",
        ]
        for title in titles {
            XCTAssertEqual(ProfanityFilter.mask(title), title)
            XCTAssertFalse(ProfanityFilter.containsProfanity(title))
        }
    }

    // MARK: - Detection

    func testContainsProfanity() {
        XCTAssertTrue(ProfanityFilter.containsProfanity("Thank Fuck It's The Weekend"))
        XCTAssertFalse(ProfanityFilter.containsProfanity("Scunthorpe United"))
        XCTAssertFalse(ProfanityFilter.containsProfanity(""))
    }

    func testEmptyAndCleanStringsAreReturnedUnchanged() {
        XCTAssertEqual(ProfanityFilter.mask(""), "")
        XCTAssertEqual(ProfanityFilter.mask("   "), "   ")
    }

    // MARK: - Integration with the template

    private let explicit = TrackPresence(
        trackName: "Thank Fuck It's The Weekend",
        artists: ["Shit Robot"],
        albumName: nil,
        isPlaying: true,
        trackID: "explicit"
    )

    func testRenderMasksTrackAndArtist() {
        XCTAssertEqual(StatusTemplate().render(explicit),
                       "♪ Thank F**k It's The Weekend by S**t Robot")
    }

    func testRenderCanBeOptedOut() {
        XCTAssertEqual(StatusTemplate().render(explicit, maskProfanity: false),
                       "♪ Thank Fuck It's The Weekend by Shit Robot")
    }

    /// The user's own template is theirs. Only the values that come from Spotify are
    /// masked, because those are the ones they did not choose.
    func testTheUsersOwnTemplateTextIsNotMasked() {
        let template = StatusTemplate("Fuck it — {track}")
        XCTAssertEqual(template.render(StatusTemplate.previewPresence),
                       "Fuck it — Dreams")
    }

    func testWouldMaskProfanityReportsAccurately() {
        XCTAssertTrue(StatusTemplate().wouldMaskProfanity(explicit))
        XCTAssertFalse(StatusTemplate().wouldMaskProfanity(StatusTemplate.previewPresence))
    }

    /// Masking runs before the 280-character clamp, so a masked status can never be
    /// longer than the limit and can never be truncated mid-mask.
    func testMaskedStatusStillRespectsTheCharacterLimit() {
        let long = TrackPresence(
            trackName: String(repeating: "Fucking Long Title ", count: 40),
            artists: ["Someone"],
            albumName: nil,
            isPlaying: true,
            trackID: "long"
        )
        let rendered = StatusTemplate().render(long)
        XCTAssertLessThanOrEqual(rendered.count, TeamsSelectors.statusCharacterLimit)
        XCTAssertFalse(rendered.lowercased().contains("fucking"))
    }
}
