import Foundation
import Testing
@testable import Kaset

/// Tests for SearchViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
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
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.query.isEmpty)
        #expect(self.viewModel.results.allItems.isEmpty)
        #expect(self.viewModel.selectedFilter == .all)
    }

    @Test("Query change clears results when empty")
    func queryChangeClearsResultsWhenEmpty() {
        self.viewModel.query = "test"
        self.viewModel.query = ""

        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.results.allItems.isEmpty)
    }

    @Test("Search with empty query does not call API")
    func searchWithEmptyQueryDoesNotCallAPI() {
        self.viewModel.query = ""
        self.viewModel.search()

        #expect(self.mockClient.searchCalled == false)
    }

    @Test("Clear resets state")
    func clearResetsState() {
        self.viewModel.query = "test query"
        self.viewModel.selectedFilter = .songs

        self.viewModel.clear()

        #expect(self.viewModel.query.isEmpty)
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.results.allItems.isEmpty)
    }

    @Test("Filtered items returns all when all selected")
    func filteredItemsReturnsAllWhenAllSelected() {
        self.viewModel.selectedFilter = .all

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

    @Test("Podcast filter is available")
    func podcastFilterIsAvailable() {
        let filters = SearchViewModel.SearchFilter.allCases
        #expect(filters.contains(.podcasts))
    }

    @Test("Podcast filter has correct raw value")
    func podcastFilterRawValue() {
        #expect(SearchViewModel.SearchFilter.podcasts.rawValue == "Podcasts")
    }

    @Test("Selected filter defaults to all")
    func selectedFilterDefaultsToAll() {
        #expect(self.viewModel.selectedFilter == .all)
    }

    @Test("Can set filter to podcasts")
    func canSetFilterToPodcasts() {
        self.viewModel.selectedFilter = .podcasts
        #expect(self.viewModel.selectedFilter == .podcasts)
    }

    @Test("Selecting suggestion suppresses follow-up autocomplete fetch")
    func selectingSuggestionSuppressesFollowUpAutocompleteFetch() async throws {
        let suggestion = SearchSuggestion(query: "daft punk")
        self.mockClient.searchSuggestions = [suggestion]

        self.viewModel.selectSuggestion(suggestion)

        // Mirrors SearchView's onChange(of: query) callback, which can arrive after
        // the click handler has already selected a suggestion and started search.
        self.viewModel.fetchSuggestions()
        try await Task.sleep(for: .milliseconds(250))

        #expect(self.viewModel.query == suggestion.query)
        #expect(self.viewModel.suggestions.isEmpty)
        #expect(self.viewModel.showSuggestions == false)
        #expect(self.mockClient.getSearchSuggestionsCalled == false)
    }

    @Test("Editing after submitted suggestion re-enables autocomplete")
    func editingAfterSubmittedSuggestionReenablesAutocomplete() async throws {
        let suggestion = SearchSuggestion(query: "daft punk")
        self.mockClient.searchSuggestions = [SearchSuggestion(query: "daft punk random access memories")]

        self.viewModel.selectSuggestion(suggestion)
        self.viewModel.query = "daft punk r"
        self.viewModel.fetchSuggestions()
        try await Task.sleep(for: .milliseconds(250))

        #expect(self.mockClient.getSearchSuggestionsQueries == ["daft punk r"])
        #expect(self.viewModel.suggestions.count == 1)
        #expect(self.viewModel.showSuggestions == true)
    }
}
