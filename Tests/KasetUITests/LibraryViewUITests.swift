import XCTest

/// UI tests for the LibraryView.
@MainActor
final class LibraryViewUITests: KasetUITestCase {
    // MARK: - Basic Display

    func testLibraryViewDisplaysTitle() {
        launchDefault()

        navigateToLibrary()

        // Verify Library title is displayed
        let title = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(title), "Library title should be visible")
    }

    func testLibraryViewShowsLoadingState() {
        launchDefault()

        navigateToLibrary()

        // Should eventually show content or loading
        let title = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(title, timeout: 10))
    }

    // MARK: - Playlist Display

    func testLibraryViewWithMockPlaylists() {
        launchWithMockLibrary(playlistCount: 5)

        navigateToLibrary()

        // The view should show playlists
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(waitForElement(scrollView, timeout: 10))
    }

    func testLibraryViewIsScrollable() {
        launchWithMockLibrary(playlistCount: 20)

        navigateToLibrary()

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(waitForElement(scrollView))

        scrollView.swipeUp()
        scrollView.swipeDown()
    }

    // MARK: - Navigation Integration

    func testLibraryNavigationFromSidebar() {
        launchDefault()

        // Navigate to Library via sidebar using accessibility identifier
        navigateToLibrary()

        let title = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(title))
    }

    // MARK: - Player Bar Integration

    func testLibraryViewShowsPlayerBar() {
        launchWithMockPlayer(isPlaying: true)

        navigateToLibrary()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10))
    }
}
