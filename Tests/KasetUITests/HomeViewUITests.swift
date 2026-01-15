import XCTest

/// UI tests for the HomeView.
nonisolated final class HomeViewUITests: KasetUITestCase {
    // MARK: - Basic Display

    func testHomeViewDisplaysTitle() throws {
        launchWithMockHome()

        navigateToHome()

        // Verify Home title is displayed
        let title = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(title), "Home title should be visible")
    }

    func testHomeViewShowsLoadingState() throws {
        // Launch without mock data to see loading state
        launchDefault()

        navigateToHome()

        // The view should eventually load or show content
        // In test mode, it should transition quickly
        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle, timeout: 10))
    }

    // MARK: - Content Display

    func testHomeViewDisplaysSections() throws {
        launchWithMockHome(sectionCount: 3, itemsPerSection: 5)

        navigateToHome()

        // Wait for content to load
        // Look for section titles in the scroll view
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(waitForElement(scrollView, timeout: 10), "Scroll view should exist")
    }

    func testHomeViewIsScrollable() throws {
        launchWithMockHome(sectionCount: 5, itemsPerSection: 10)

        navigateToHome()

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(waitForElement(scrollView))

        // Verify scrolling works
        scrollView.swipeUp()
        scrollView.swipeDown()
    }

    // MARK: - Player Bar Presence

    func testHomeViewShowsPlayerBar() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        // Player bar should be visible at the bottom
        // Look for play/pause button as indicator
        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10), "Player bar should show play/pause button")
    }

    // MARK: - Navigation from Home

    func testCanNavigateFromHomeToOtherViews() throws {
        launchWithMockHome()

        navigateToHome()

        // Navigate to Search
        navigateToSearch()
        let searchTitle = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(searchTitle))

        // Navigate back to Home
        navigateToHome()
        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle))
    }
}
