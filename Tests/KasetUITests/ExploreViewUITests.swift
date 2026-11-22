import XCTest

/// UI tests for the ExploreView.
@MainActor
final class ExploreViewUITests: KasetUITestCase {
    func testExploreViewDisplaysTitle() {
        launchDefault()

        navigateToExplore()

        let title = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(title), "Explore title should be visible")
    }

    func testExploreViewShowsContent() {
        launchWithMockHome() // Explore uses same mock data format

        navigateToExplore()

        let scrollView = app.scrollViews["exploreView.scrollView"].firstMatch
        XCTAssertTrue(waitForElement(scrollView, timeout: 10))
    }

    func testExploreViewIsScrollable() {
        launchWithMockHome(sectionCount: 5)

        navigateToExplore()

        let scrollView = app.scrollViews["exploreView.scrollView"].firstMatch
        XCTAssertTrue(waitForElement(scrollView))

        scrollView.swipeUp()
        scrollView.swipeDown()
    }

    func testExploreNavigationFromSidebar() {
        launchDefault()

        navigateToExplore()

        let title = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(title))
    }

    func testExploreViewShowsPlayerBar() {
        launchWithMockPlayer(isPlaying: true)

        navigateToExplore()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10))
    }
}
