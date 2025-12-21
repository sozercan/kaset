import XCTest

/// UI tests for the LibraryView (Playlists).
final class LibraryViewUITests: KasetUITestCase {
    // MARK: - Basic Display

    func testLibraryViewDisplaysTitle() throws {
        launchDefault()

        navigateToLibrary()

        // Verify Playlists title is displayed
        let title = app.staticTexts["Playlists"]
        XCTAssertTrue(waitForElement(title), "Playlists title should be visible")
    }

    func testLibraryViewShowsLoadingState() throws {
        launchDefault()

        navigateToLibrary()

        // Should eventually show content or loading
        let title = app.staticTexts["Playlists"]
        XCTAssertTrue(waitForElement(title, timeout: 10))
    }

    // MARK: - Playlist Display

    func testLibraryViewWithMockPlaylists() throws {
        launchWithMockLibrary(playlistCount: 5)

        navigateToLibrary()

        // The view should show playlists
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(waitForElement(scrollView, timeout: 10))
    }

    func testLibraryViewIsScrollable() throws {
        launchWithMockLibrary(playlistCount: 20)

        navigateToLibrary()

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(waitForElement(scrollView))

        scrollView.swipeUp()
        scrollView.swipeDown()
    }

    // MARK: - Navigation Integration

    func testLibraryNavigationFromSidebar() throws {
        launchDefault()

        // Navigate to Library via sidebar using accessibility identifier
        navigateToLibrary()

        let title = app.staticTexts["Playlists"]
        XCTAssertTrue(waitForElement(title))
    }

    // MARK: - Player Bar Integration

    func testLibraryViewShowsPlayerBar() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToLibrary()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10))
    }
}
