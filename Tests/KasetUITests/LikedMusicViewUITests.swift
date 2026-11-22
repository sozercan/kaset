import XCTest

/// UI tests for the LikedMusicView.
@MainActor
final class LikedMusicViewUITests: KasetUITestCase {
    func testLikedMusicViewDisplaysTitle() {
        launchDefault()

        navigateToLikedMusic()

        let title = app.staticTexts["Liked Music"]
        XCTAssertTrue(waitForElement(title), "Liked Music title should be visible")
    }

    func testLikedMusicViewShowsEmptyState() {
        launchDefault()

        navigateToLikedMusic()

        // With no liked songs, should show empty state or loading
        let title = app.staticTexts["Liked Music"]
        XCTAssertTrue(waitForElement(title, timeout: 10))
    }

    func testLikedMusicNavigationFromSidebar() {
        launchDefault()

        navigateToLikedMusic()

        let title = app.staticTexts["Liked Music"]
        XCTAssertTrue(waitForElement(title))
    }

    func testLikedMusicViewShowsPlayerBar() {
        launchWithMockPlayer(isPlaying: true)

        navigateToLikedMusic()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10))
    }
}
