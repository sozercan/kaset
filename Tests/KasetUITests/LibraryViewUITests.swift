import XCTest

@MainActor
final class LibraryViewUITests: KasetUITestCase {
    func testLibraryViewDisplaysTitle() {
        launchDefault()

        navigateToLibrary()

        let title = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(title), "Library title should be visible")
    }

    func testLibraryViewShowsLoadingState() {
        launchDefault()

        navigateToLibrary()

        let title = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(title, timeout: 10))
    }

    func testLibraryViewWithMockPlaylists() {
        launchWithMockLibrary(playlistCount: 5)

        navigateToLibrary()

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

    func testLibraryNavigationFromSidebar() {
        launchDefault()

        navigateToLibrary()

        let title = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(title))
    }

    func testLibraryViewShowsPlayerBar() {
        launchWithMockPlayer(isPlaying: true)

        navigateToLibrary()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10))
    }
}
