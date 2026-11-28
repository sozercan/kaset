import XCTest

@MainActor
final class SearchViewUITests: KasetUITestCase {
    func testSearchFieldExists() {
        launchDefault()

        navigateToSearch()

        let searchField = app.textFields[TestAccessibilityID.Search.searchField]
        XCTAssertTrue(waitForElement(searchField), "Search field should exist")
    }

    func testSearchFieldAcceptsInput() {
        launchDefault()

        navigateToSearch()

        let searchField = app.textFields[TestAccessibilityID.Search.searchField]
        XCTAssertTrue(waitForHittable(searchField))

        searchField.click()
        searchField.typeText("test query")

        XCTAssertEqual(searchField.value as? String, "test query")
    }

    func testClearButtonAppearsWithText() {
        launchDefault()

        navigateToSearch()

        let searchField = app.textFields[TestAccessibilityID.Search.searchField]
        XCTAssertTrue(waitForHittable(searchField))

        searchField.click()
        searchField.typeText("test")

        let clearButton = app.buttons[TestAccessibilityID.Search.clearButton]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 3), "Clear button should appear")
    }

    func testEmptyStateShownInitially() {
        launchDefault()

        navigateToSearch()

        let emptyStateText = app.staticTexts["Search for your favorite music"]
        XCTAssertTrue(waitForElement(emptyStateText, timeout: 5), "Empty state text should be visible")
    }

    func testSearchSubmitTriggersSearch() {
        launchWithMockSearch(songCount: 5)

        navigateToSearch()

        let searchField = app.textFields[TestAccessibilityID.Search.searchField]
        XCTAssertTrue(waitForHittable(searchField))

        searchField.click()
        searchField.typeText("test\n")

        let firstResult = app.buttons[TestAccessibilityID.Search.resultRow(index: 0)]
        XCTAssertTrue(
            waitForElement(firstResult, timeout: 10),
            "Submitting a search should render the mock search results"
        )
    }

    func testFilterChipsExistAfterSearch() {
        launchWithMockSearch(songCount: 5)

        navigateToSearch()

        let searchField = app.textFields[TestAccessibilityID.Search.searchField]
        XCTAssertTrue(waitForHittable(searchField))

        searchField.click()
        searchField.typeText("test\n")

        let allFilterButton = app.buttons["All"]
        let songsFilterButton = app.buttons["Songs"]
        XCTAssertTrue(
            waitForElement(allFilterButton, timeout: 10),
            "All filter chip should appear after search results load"
        )
        XCTAssertTrue(
            waitForElement(songsFilterButton, timeout: 5),
            "Songs filter chip should appear after search results load"
        )
    }

    func testSearchFieldIsFocusedOnAppear() {
        launchDefault()

        navigateToSearch()

        let searchField = app.textFields[TestAccessibilityID.Search.searchField]
        XCTAssertTrue(waitForElement(searchField))

        app.typeText("quick search")

        XCTAssertEqual(searchField.value as? String, "quick search")
    }

    func testSearchNavigationTitle() {
        launchDefault()

        navigateToSearch()

        let title = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(title), "Search title should be visible")
    }

    func testReselectingSearchPopsNestedNavigationToRoot() {
        launchWithMockSearch(songCount: 1)
        navigateToSearch()

        let searchField = app.textFields[TestAccessibilityID.Search.searchField]
        XCTAssertTrue(waitForHittable(searchField))
        searchField.click()
        searchField.typeText("test\n")

        let firstResult = app.buttons[TestAccessibilityID.Search.resultRow(index: 0)]
        XCTAssertTrue(waitForHittable(firstResult), "A mock search result should appear")
        firstResult.rightClick()

        let goToAlbum = app.menuItems["Go to Album"]
        XCTAssertTrue(waitForHittable(goToAlbum), "The result context menu should offer album navigation")
        goToAlbum.click()

        XCTAssertTrue(
            waitForElementToDisappear(searchField),
            "Navigating to the album should hide the Search root"
        )

        navigateToSearch()

        XCTAssertTrue(
            waitForHittable(searchField),
            "Re-selecting Search should pop its nested navigation and restore the search field"
        )
    }
}
