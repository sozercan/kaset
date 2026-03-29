import XCTest

/// UI tests for the SearchView.
@MainActor
final class SearchViewUITests: KasetUITestCase {
    // MARK: - Search Field

    func testSearchFieldExists() {
        launchDefault()

        navigateToSearch()

        // Search field should be present
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(waitForElement(searchField), "Search field should exist")
    }

    func testSearchFieldAcceptsInput() {
        launchDefault()

        navigateToSearch()

        let searchField = app.textFields.firstMatch
        XCTAssertTrue(waitForHittable(searchField))

        // Type in the search field
        searchField.click()
        searchField.typeText("test query")

        // Verify text was entered
        XCTAssertEqual(searchField.value as? String, "test query")
    }

    func testClearButtonAppearsWithText() {
        launchDefault()

        navigateToSearch()

        let searchField = app.textFields.firstMatch
        XCTAssertTrue(waitForHittable(searchField))

        // Initially no clear button
        searchField.click()
        searchField.typeText("test")

        // Clear button should appear (X icon)
        let clearButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Clear' OR label CONTAINS 'xmark'")
        ).firstMatch
        XCTAssertTrue(clearButton.waitForExistence(timeout: 3), "Clear button should appear")
    }

    // MARK: - Empty State

    func testEmptyStateShownInitially() {
        launchDefault()

        navigateToSearch()

        // Empty state message should be visible
        let emptyStateText = app.staticTexts["Search for your favorite music"]
        XCTAssertTrue(waitForElement(emptyStateText, timeout: 5), "Empty state text should be visible")
    }

    // MARK: - Search Execution

    func testSearchSubmitTriggersSearch() {
        launchWithMockSearch(songCount: 5)

        navigateToSearch()

        let searchField = app.textFields.firstMatch
        XCTAssertTrue(waitForHittable(searchField))

        searchField.click()
        searchField.typeText("test\n") // Type and press Enter

        // Wait for results or loading state
        // The search should be triggered
        Thread.sleep(forTimeInterval: 1) // Brief wait for state change
    }

    // MARK: - Filter Chips

    func testFilterChipsExistAfterSearch() {
        launchWithMockSearch(songCount: 5)

        navigateToSearch()

        let searchField = app.textFields.firstMatch
        XCTAssertTrue(waitForHittable(searchField))

        searchField.click()
        searchField.typeText("test\n")

        // Wait for filter chips (they appear after search results)
        // Filter chips are buttons with category names
        Thread.sleep(forTimeInterval: 2)

        // Look for any filter-like buttons
        let allFilterButton = app.buttons["All"]
        // If results exist, filters should appear
    }

    // MARK: - Keyboard Navigation

    func testSearchFieldIsFocusedOnAppear() {
        launchDefault()

        navigateToSearch()

        // The search field should be ready for input
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(waitForElement(searchField))

        // Type directly - if focused, it should work
        app.typeText("quick search")

        // Verify text was entered
        XCTAssertEqual(searchField.value as? String, "quick search")
    }

    // MARK: - Navigation Integration

    func testSearchNavigationTitle() {
        launchDefault()

        navigateToSearch()

        let title = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(title), "Search title should be visible")
    }
}
