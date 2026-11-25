import XCTest

@MainActor
final class HomeViewUITests: KasetUITestCase {
    func testHomeViewDisplaysTitle() {
        launchWithMockHome()

        navigateToHome()

        let title = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(title), "Home title should be visible")
    }

    func testHomeViewShowsLoadingState() {
        launchDefault()

        navigateToHome()

        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle, timeout: 10))
    }

    func testHomeViewDisplaysSections() {
        launchWithMockHome(sectionCount: 3, itemsPerSection: 5)

        navigateToHome()

        let scrollView = app.scrollViews[TestAccessibilityID.Home.scrollView]
        XCTAssertTrue(waitForElement(scrollView, timeout: 10), "Scroll view should exist")
    }

    func testHomeViewIsScrollable() {
        launchWithMockHome(sectionCount: 5, itemsPerSection: 10)

        navigateToHome()

        let scrollView = app.scrollViews[TestAccessibilityID.Home.scrollView]
        XCTAssertTrue(waitForElement(scrollView))

        scrollView.swipeUp()
        scrollView.swipeDown()
    }

    func testHomeViewShowsPlayerBar() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10), "Player bar should show play/pause button")
    }

    func testCanNavigateFromHomeToOtherViews() {
        launchWithMockHome()

        navigateToHome()

        navigateToSearch()
        let searchTitle = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(searchTitle))

        navigateToHome()
        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle))
    }
}
