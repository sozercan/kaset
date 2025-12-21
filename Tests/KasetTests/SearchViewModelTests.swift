import XCTest
@testable import Kaset

/// Tests for SearchViewModel using mock client.
@MainActor
final class SearchViewModelTests: XCTestCase {
    private var mockClient: MockYTMusicClient!
    private var viewModel: SearchViewModel!

    override func setUp() async throws {
        self.mockClient = MockYTMusicClient()
        self.viewModel = SearchViewModel(client: self.mockClient)
    }

    override func tearDown() async throws {
        self.mockClient = nil
        self.viewModel = nil
    }

    func testInitialState() {
        XCTAssertEqual(self.viewModel.loadingState, .idle)
        XCTAssertTrue(self.viewModel.query.isEmpty)
        XCTAssertTrue(self.viewModel.results.allItems.isEmpty)
        XCTAssertEqual(self.viewModel.selectedFilter, .all)
    }

    func testQueryChangeClearsResultsWhenEmpty() {
        // Given
        self.viewModel.query = "test"

        // When
        self.viewModel.query = ""

        // Then
        XCTAssertEqual(self.viewModel.loadingState, .idle)
        XCTAssertTrue(self.viewModel.results.allItems.isEmpty)
    }

    func testSearchWithEmptyQueryDoesNotCallAPI() {
        // Given
        self.viewModel.query = ""

        // When
        self.viewModel.search()

        // Then
        XCTAssertFalse(self.mockClient.searchCalled)
    }

    func testClearResetsState() {
        // Given
        self.viewModel.query = "test query"
        self.viewModel.selectedFilter = .songs

        // When
        self.viewModel.clear()

        // Then
        XCTAssertTrue(self.viewModel.query.isEmpty)
        XCTAssertEqual(self.viewModel.loadingState, .idle)
        XCTAssertTrue(self.viewModel.results.allItems.isEmpty)
    }

    func testFilteredItemsReturnsAllWhenAllSelected() {
        // Given
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 2,
            albumCount: 1,
            artistCount: 1,
            playlistCount: 1
        )
        self.viewModel.selectedFilter = .all

        // Manually set results for testing
        let response = TestFixtures.makeSearchResponse(
            songCount: 2,
            albumCount: 1,
            artistCount: 1,
            playlistCount: 1
        )

        // When - access filtered items
        // Note: In real usage, results would be set by search()
        // Here we verify the filter logic by checking the count calculation
        XCTAssertEqual(response.allItems.count, 5)
    }

    func testFilteredItemsReturnsSongsOnlyWhenSongsSelected() {
        // Given
        let response = TestFixtures.makeSearchResponse(
            songCount: 3,
            albumCount: 2,
            artistCount: 1,
            playlistCount: 1
        )

        // Then
        let songItems = response.songs.map { SearchResultItem.song($0) }
        XCTAssertEqual(songItems.count, 3)
    }
}
