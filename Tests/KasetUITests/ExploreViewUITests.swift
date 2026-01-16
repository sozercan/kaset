import XCTest

/// UI tests for the ExploreView.
@MainActor
final class ExploreViewUITests: KasetUITestCase {
    // MARK: - Basic Display

    func testExploreViewDisplaysTitle() throws {
        launchDefault()

        navigateToExplore()

        let title = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(title), "Explore title should be visible")
    }

    func testExploreViewShowsContent() throws {
        launchWithMockHome() // Explore uses same mock data format

        navigateToExplore()

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(waitForElement(scrollView, timeout: 10))
    }

    func testExploreViewIsScrollable() throws {
        launchWithMockHome(sectionCount: 5)

        navigateToExplore()

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(waitForElement(scrollView))

        scrollView.swipeUp()
        scrollView.swipeDown()
    }

    // MARK: - Navigation

    func testExploreNavigationFromSidebar() throws {
        launchDefault()

        navigateToExplore()

        let title = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(title))
    }

    // MARK: - Player Bar Integration

    func testExploreViewShowsPlayerBar() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToExplore()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10))
    }
}
