import XCTest

@MainActor
final class SidebarUITests: KasetUITestCase {
    func testSidebarShowsAllNavigationItems() {
        launchDefault()

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

    func testNavigateToHome() {
        launchDefault()

        navigateToHome()

        let navigationTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(navigationTitle), "Home navigation title should be visible")
    }

    func testNavigateToSearch() {
        launchDefault()

        navigateToSearch()

        let navigationTitle = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(navigationTitle), "Search navigation title should be visible")

        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.exists, "Search field should exist")
    }

    func testNavigateToExplore() {
        launchDefault()

        navigateToExplore()

        let navigationTitle = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(navigationTitle), "Explore navigation title should be visible")
    }

    func testNavigateToLikedMusic() {
        launchDefault()

        navigateToLikedMusic()

        let navigationTitle = app.staticTexts["Liked Music"]
        XCTAssertTrue(waitForElement(navigationTitle), "Liked Music navigation title should be visible")
    }

    func testNavigateToLibrary() {
        launchDefault()

        navigateToLibrary()

        let navigationTitle = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(navigationTitle), "Library navigation title should be visible")
    }

    func testNavigationPersistsAfterSwitching() {
        launchDefault()

        navigateToSearch()
        let searchTitle = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(searchTitle))

        navigateToExplore()
        let exploreTitle = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(exploreTitle))

        navigateToHome()
        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle))
    }
}
