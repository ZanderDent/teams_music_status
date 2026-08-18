import XCTest
@testable import TeamsMusicStatusCore

/// Spotify wire-format parsing and — the part that actually bites — error classification.
final class SpotifyWebAPITests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: Parsing

    func testParsesTrackArtistsAndAlbum() {
        let presence = SpotifyWebAPISource.parse(data("""
        {"is_playing": true, "currently_playing_type": "track",
         "item": {"id": "abc", "name": "Define",
                  "artists": [{"name": "Dom Dolla"}, {"name": "Go Freek"}],
                  "album": {"name": "Define"}}}
        """))
        XCTAssertEqual(presence?.trackName, "Define")
        XCTAssertEqual(presence?.artists, ["Dom Dolla", "Go Freek"])
        XCTAssertEqual(presence?.albumName, "Define")
        XCTAssertEqual(presence?.trackID, "abc")
        XCTAssertEqual(presence?.isPlaying, true)
    }

    func testPausedPlaybackIsStillAReading() {
        let presence = SpotifyWebAPISource.parse(data("""
        {"is_playing": false, "item": {"id": "x", "name": "Dreams",
         "artists": [{"name": "Fleetwood Mac"}]}}
        """))
        XCTAssertEqual(presence?.isPlaying, false)
        XCTAssertEqual(presence?.trackName, "Dreams")
    }

    func testNullItemMeansNoPlayback() {
        XCTAssertNil(SpotifyWebAPISource.parse(data(#"{"is_playing": false, "item": null}"#)))
    }

    /// Adverts and podcasts have no meaningful artist; publishing them would be misleading.
    func testNonTrackContentIsIgnored() {
        XCTAssertNil(SpotifyWebAPISource.parse(data("""
        {"is_playing": true, "currently_playing_type": "ad",
         "item": {"id": "ad", "name": "Advertisement", "artists": []}}
        """)))
    }

    func testMalformedBodyIsSurvivable() {
        XCTAssertNil(SpotifyWebAPISource.parse(data("not json at all")))
        XCTAssertNil(SpotifyWebAPISource.parse(Data()))
    }

    // MARK: Error classification

    /// The Phase 0 finding that matters most: Spotify answers an insufficient-scope
    /// request with **401 "Permissions missing"**, not 403. Treating that as an expired
    /// token sends the app into an endless refresh loop.
    func testPermissionsMissing401IsNotTreatedAsExpiry() {
        let error = SpotifyWebAPISource.classify(
            status: 401,
            body: data(#"{"error": {"status": 401, "message": "Permissions missing"}}"#))
        XCTAssertEqual(error, .permissionsMissing("Permissions missing"))
        XCTAssertTrue(error.requiresReauthorization)
        XCTAssertFalse(error.isTransient)
    }

    func testOrdinary401IsTreatedAsExpiredToken() {
        let error = SpotifyWebAPISource.classify(
            status: 401,
            body: data(#"{"error": {"status": 401, "message": "The access token expired"}}"#))
        XCTAssertEqual(error, .authorizationExpired)
        XCTAssertTrue(error.requiresReauthorization)
    }

    func test401WithNoBodyIsTreatedAsExpiredToken() {
        XCTAssertEqual(SpotifyWebAPISource.classify(status: 401, body: Data()),
                       .authorizationExpired)
    }

    func test403IsAPermissionProblem() {
        let error = SpotifyWebAPISource.classify(
            status: 403, body: data(#"{"error": {"status": 403, "message": "Forbidden"}}"#))
        XCTAssertEqual(error, .permissionsMissing("Forbidden"))
    }

    func testServerErrorsAreTransient() {
        let error = SpotifyWebAPISource.classify(status: 503, body: Data())
        XCTAssertEqual(error, .serviceError(status: 503, message: nil))
        XCTAssertTrue(error.isTransient)
        XCTAssertFalse(error.requiresReauthorization)
    }

    func testRateLimitIsTransientAndNotAReauthorization() {
        let error = PresenceSourceError.rateLimited(retryAfter: 30)
        XCTAssertTrue(error.isTransient)
        XCTAssertFalse(error.requiresReauthorization)
    }

    // MARK: PKCE

    func testPKCEChallengeMatchesTheRFCExample() {
        // RFC 7636 appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(SpotifyAuth.challenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierLengthIsWithinSpotifysAllowedRange() {
        for _ in 0..<20 {
            let verifier = SpotifyAuth.makeVerifier()
            XCTAssertGreaterThanOrEqual(verifier.count, 43)
            XCTAssertLessThanOrEqual(verifier.count, 128)
            // Only the unreserved characters PKCE permits.
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            XCTAssertTrue(verifier.unicodeScalars.allSatisfy(allowed.contains))
        }
    }

    func testVerifiersAreNotRepeated() {
        let verifiers = Set((0..<50).map { _ in SpotifyAuth.makeVerifier() })
        XCTAssertEqual(verifiers.count, 50)
    }

    func testBase64URLHasNoPaddingOrUnsafeCharacters() {
        let encoded = SpotifyAuth.base64URL(Data([251, 255, 190, 0, 1]))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }
}

/// The AppleScript source's parsing, which has to cope with a tab-delimited string.
/// Superseded by `SpotifyLocalSourceTests.swift`, which covers the same ground against
/// the reading-based API. Kept here only for the cases about text handling, which are
/// about the parser rather than the error model.
final class SpotifyLocalTextTests: XCTestCase {

    /// Track names legitimately contain unusual characters; only tabs are structural.
    func testTrackNamesWithPunctuationSurvive() throws {
        let reading = try SpotifyLocalSource.parse(
            "playing\tTake me back to 97\u{2019} \u{2014} Remix\tCody Wong\tAlbum\tspotify:track:y")
        XCTAssertEqual(reading.presence?.trackName, "Take me back to 97\u{2019} \u{2014} Remix")
    }

    func testTabSeparatedFieldsAreReadPositionally() throws {
        let reading = try SpotifyLocalSource.parse(
            "playing\tDefine\tDom Dolla\tDefine\tspotify:track:3B1Je3rlEac3p4ikYW13zw")
        XCTAssertEqual(reading.presence?.trackName, "Define")
        XCTAssertEqual(reading.presence?.artists, ["Dom Dolla"])
        XCTAssertEqual(reading.presence?.trackID, "3B1Je3rlEac3p4ikYW13zw")
    }
}
