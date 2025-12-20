import XCTest
@testable import YouTubeMusic

/// Main test suite for YouTube Music app.
final class YouTubeMusicTests: XCTestCase {
    func testAppConfiguration() {
        // Verify app can be configured correctly
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
    }

    func testYTMusicErrorDescriptions() {
        // Test error descriptions
        let authExpired = YTMusicError.authExpired
        XCTAssertNotNil(authExpired.errorDescription)
        XCTAssertTrue(authExpired.requiresReauth)

        let notAuthenticated = YTMusicError.notAuthenticated
        XCTAssertNotNil(notAuthenticated.errorDescription)
        XCTAssertTrue(notAuthenticated.requiresReauth)

        let networkError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        XCTAssertNotNil(networkError.errorDescription)
        XCTAssertFalse(networkError.requiresReauth)

        let parseError = YTMusicError.parseError(message: "Test error")
        XCTAssertNotNil(parseError.errorDescription)
        XCTAssertTrue(parseError.errorDescription?.contains("Test error") ?? false)
    }

    func testSongDurationParsing() {
        // Test duration formatting
        let song = Song(
            id: "test",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: 185, // 3:05
            thumbnailURL: nil,
            videoId: "test"
        )

        XCTAssertEqual(song.durationDisplay, "3:05")
    }

    func testSongDurationDisplayWithNoDuration() {
        let song = Song(
            id: "test",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: "test"
        )

        XCTAssertEqual(song.durationDisplay, "--:--")
    }

    func testTimeIntervalFormattedDuration() {
        XCTAssertEqual(TimeInterval(65).formattedDuration, "1:05")
        XCTAssertEqual(TimeInterval(0).formattedDuration, "0:00")
        XCTAssertEqual(TimeInterval(3661).formattedDuration, "1:01:01")
    }

    func testSearchResponseEmpty() {
        let empty = SearchResponse.empty
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.allItems.isEmpty)
    }

    func testHomeResponseEmpty() {
        let empty = HomeResponse.empty
        XCTAssertTrue(empty.isEmpty)
    }
}
