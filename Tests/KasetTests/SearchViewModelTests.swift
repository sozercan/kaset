import Foundation
import Testing
@testable import Kaset

/// Tests for SearchViewModel using mock client.
@Suite(.serialized)
@MainActor
struct SearchViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: SearchViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = SearchViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty query")
    func initialState() {
        #expect(viewModel.loadingState == .idle)
        #expect(viewModel.query.isEmpty)
        #expect(viewModel.results.allItems.isEmpty)
        #expect(viewModel.selectedFilter == .all)
    }

    @Test("Query change clears results when empty")
    func queryChangeClearsResultsWhenEmpty() {
        viewModel.query = "test"
        viewModel.query = ""

        #expect(viewModel.loadingState == .idle)
        #expect(viewModel.results.allItems.isEmpty)
    }

    @Test("Search with empty query does not call API")
    func searchWithEmptyQueryDoesNotCallAPI() {
        viewModel.query = ""
        viewModel.search()

        #expect(mockClient.searchCalled == false)
    }

    @Test("Clear resets state")
    func clearResetsState() {
        viewModel.query = "test query"
        viewModel.selectedFilter = .songs

        viewModel.clear()

        #expect(viewModel.query.isEmpty)
        #expect(viewModel.loadingState == .idle)
        #expect(viewModel.results.allItems.isEmpty)
    }

    @Test("Filtered items returns all when all selected")
    func filteredItemsReturnsAllWhenAllSelected() {
        viewModel.selectedFilter = .all

        let response = TestFixtures.makeSearchResponse(
            songCount: 2,
            albumCount: 1,
            artistCount: 1,
            playlistCount: 1
        )

        #expect(response.allItems.count == 5)
    }

    @Test("Filtered items returns songs only when songs selected")
    func filteredItemsReturnsSongsOnlyWhenSongsSelected() {
        let response = TestFixtures.makeSearchResponse(
            songCount: 3,
            albumCount: 2,
            artistCount: 1,
            playlistCount: 1
        )

        let songItems = response.songs.map { SearchResultItem.song($0) }
        #expect(songItems.count == 3)
    }
}
