import XCTest

/// UI tests for sidebar navigation.
@MainActor
final class SidebarUITests: KasetUITestCase {
    // MARK: - Navigation Items Visible

    func testSidebarShowsAllNavigationItems() throws {
        launchDefault()

        // Verify all sidebar items are present via accessibility identifiers
        let searchItem = app.buttons[TestAccessibilityID.Sidebar.searchItem]
        let homeItem = app.buttons[TestAccessibilityID.Sidebar.homeItem]
        let exploreItem = app.buttons[TestAccessibilityID.Sidebar.exploreItem]
        let likedMusicItem = app.buttons[TestAccessibilityID.Sidebar.likedMusicItem]
        let playlistsItem = app.buttons[TestAccessibilityID.Sidebar.libraryItem]

        XCTAssertTrue(searchItem.waitForExistence(timeout: 10), "Search item should exist")
        XCTAssertTrue(homeItem.exists, "Home item should exist")
        XCTAssertTrue(exploreItem.exists, "Explore item should exist")
        XCTAssertTrue(likedMusicItem.exists, "Liked Music item should exist")
        XCTAssertTrue(playlistsItem.exists, "Playlists item should exist")
    }

    // MARK: - Navigation Selection

    func testNavigateToHome() throws {
        launchDefault()

        navigateToHome()

        // Verify Home view is displayed (check for navigation title)
        let navigationTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(navigationTitle), "Home navigation title should be visible")
    }

    func testNavigateToSearch() throws {
        launchDefault()

        navigateToSearch()

        // Verify Search view is displayed
        let navigationTitle = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(navigationTitle), "Search navigation title should be visible")

        // Search field should be present
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.exists, "Search field should exist")
    }

    func testNavigateToExplore() throws {
        launchDefault()

        navigateToExplore()

        // Verify Explore view is displayed
        let navigationTitle = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(navigationTitle), "Explore navigation title should be visible")
    }

    func testNavigateToLikedMusic() throws {
        launchDefault()

        navigateToLikedMusic()

        // Verify Liked Music view is displayed
        let navigationTitle = app.staticTexts["Liked Music"]
        XCTAssertTrue(waitForElement(navigationTitle), "Liked Music navigation title should be visible")
    }

    func testNavigateToLibrary() throws {
        launchDefault()

        navigateToLibrary()

        // Verify Library view is displayed
        let navigationTitle = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(navigationTitle), "Library navigation title should be visible")
    }

    // MARK: - Navigation Persistence

    func testNavigationPersistsAfterSwitching() throws {
        launchDefault()

        // Navigate to Search
        navigateToSearch()
        let searchTitle = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(searchTitle))

        // Navigate to Explore
        navigateToExplore()
        let exploreTitle = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(exploreTitle))

        // Navigate back to Home
        navigateToHome()
        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle))
    }
}
