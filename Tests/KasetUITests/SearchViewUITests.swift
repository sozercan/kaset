import XCTest

/// UI tests for the search overlay and results page flow.
@MainActor
final class SearchViewUITests: KasetUITestCase {
    private func launchWithSearchOverlay(songCount: Int? = nil, history: [String] = [], query: String? = nil) {
        self.app.launchArguments.append("-OpenSearchOverlay")
        self.app.launchEnvironment["OPEN_SEARCH_OVERLAY"] = "1"

        if let query {
            self.app.launchEnvironment["MOCK_SEARCH_OVERLAY_QUERY"] = query
        }

        if !history.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: history),
           let json = String(data: data, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_SEARCH_HISTORY"] = json
        }

        if let songCount {
            let songs = (0 ..< songCount).map { index in
                [
                    "id": "search-song-\(index)",
                    "title": "Search Result \(index)",
                    "artist": "Search Artist \(index)",
                    "videoId": "search-video-\(index)",
                ]
            }

            if let data = try? JSONSerialization.data(withJSONObject: ["songs": songs]),
               let json = String(data: data, encoding: .utf8)
            {
                self.app.launchEnvironment["MOCK_SEARCH_RESULTS"] = json
            }
        }

        self.app.launch()
    }

    // MARK: - Overlay Presentation

    func testSearchOverlayOpensFromLaunchArgument() {
        self.launchWithSearchOverlay()

        let searchField = self.app.textFields[TestAccessibilityID.SearchOverlay.input]
        XCTAssertTrue(self.waitForElement(searchField), "Search overlay input should exist")
    }

    func testSearchOverlayShowsSubmitAffordanceForPrefilledQuery() {
        self.launchWithSearchOverlay(query: "test")

        let searchField = self.app.textFields[TestAccessibilityID.SearchOverlay.input]
        XCTAssertTrue(self.waitForElement(searchField))

        let submitButton = self.app.buttons[TestAccessibilityID.SearchOverlay.returnHint]
        XCTAssertTrue(self.waitForElement(submitButton), "Search overlay submit button should appear for a non-empty query")
    }

    // MARK: - Search Execution

    func testSearchOverlaySubmitShowsResultsPage() {
        self.launchWithSearchOverlay(songCount: 5, query: "test")

        let searchField = self.app.textFields[TestAccessibilityID.SearchOverlay.input]
        XCTAssertTrue(self.waitForElement(searchField))

        let submitButton = self.app.buttons[TestAccessibilityID.SearchOverlay.returnHint]
        XCTAssertTrue(self.waitForElement(submitButton), "Search overlay submit button should appear")
        submitButton.click()

        XCTAssertTrue(self.waitForElementToDisappear(searchField, timeout: 10), "Search overlay input should close after search")

        let title = self.app.staticTexts["Search"]
        XCTAssertTrue(self.waitForElement(title), "Search title should be visible")

        let firstResult = self.app.buttons[TestAccessibilityID.Search.resultRow(index: 0)]
        XCTAssertTrue(self.waitForElement(firstResult, timeout: 10), "Search results should be visible")

        XCTAssertTrue(self.app.buttons["All"].exists, "Results page should keep the search category tabs")
        XCTAssertTrue(self.app.buttons["Songs"].exists, "Results page should show the Songs category tab")
        XCTAssertTrue(self.app.buttons["Albums"].exists, "Results page should show the Albums category tab")
        XCTAssertTrue(self.app.buttons["Artists"].exists, "Results page should show the Artists category tab")

        let inPageField = self.app.textFields[TestAccessibilityID.Search.searchField]
        XCTAssertFalse(inPageField.exists, "Results page should not show the old in-page search field")
    }

    // MARK: - Search History

    func testHistoryRowSelectionSubmitsSearch() {
        self.launchWithSearchOverlay(songCount: 1, history: ["success"], query: "suc")

        let searchField = self.app.textFields[TestAccessibilityID.SearchOverlay.input]
        XCTAssertTrue(self.waitForElement(searchField))

        let firstHistoryRow = self.app.buttons[TestAccessibilityID.SearchOverlay.historyRow(index: 0)]
        XCTAssertTrue(self.waitForElement(firstHistoryRow), "Matching history row should appear while typing")

        firstHistoryRow.click()

        XCTAssertTrue(self.waitForElementToDisappear(searchField, timeout: 10), "Search overlay input should close after selecting history")
    }
}
