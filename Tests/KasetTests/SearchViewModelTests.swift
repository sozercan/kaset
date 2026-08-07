import Foundation
import Testing
@testable import Kaset

// MARK: - SearchViewModelTests

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

    private func waitForSuggestionFetch(
        query: String,
        timeout: Duration = .seconds(3)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if self.mockClient.getSearchSuggestionsQueries.contains(query) {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        Issue.record("Timed out waiting for suggestion fetch for query: \(query)")
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        description: String,
        timeout: Duration = .seconds(3)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("Timed out waiting for \(description)")
    }

    private var isErrorLoadingState: Bool {
        if case .error = self.viewModel.loadingState {
            return true
        }
        return false
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

    @Test("Video, profile, and episode filters are available")
    func newSemanticFiltersAreAvailable() {
        let filters = SearchViewModel.SearchFilter.allCases
        #expect(filters.contains(.videos))
        #expect(filters.contains(.profiles))
        #expect(filters.contains(.episodes))
        #expect(SearchViewModel.SearchFilter.videos.displayName == String(localized: "Videos"))
        #expect(SearchViewModel.SearchFilter.profiles.displayName == String(localized: "Profiles"))
        #expect(SearchViewModel.SearchFilter.episodes.displayName == String(localized: "Episodes"))
    }

    @Test(
        "New semantic filters route to their dedicated endpoints",
        arguments: [
            (SearchViewModel.SearchFilter.videos, MockYTMusicClient.SearchEndpoint.videos),
            (SearchViewModel.SearchFilter.profiles, MockYTMusicClient.SearchEndpoint.profiles),
            (SearchViewModel.SearchFilter.episodes, MockYTMusicClient.SearchEndpoint.episodes),
        ]
    )
    func newSemanticFiltersRoute(
        filter: SearchViewModel.SearchFilter,
        endpoint: MockYTMusicClient.SearchEndpoint
    ) async {
        self.viewModel.query = "semantic"
        self.viewModel.selectedFilter = filter

        await self.waitUntil(
            self.mockClient.completedSearchEndpoints.contains(endpoint),
            description: "\(filter.rawValue) search endpoint"
        )

        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Albums filter preserves audiobook semantics")
    func albumsFilterIncludesAudiobooks() async {
        let album = Album(
            id: "MPREalbum",
            title: "Album",
            artists: nil,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )
        let audiobook = Album(
            id: "MPREb_audiobook",
            title: "Audiobook",
            artists: nil,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )
        self.mockClient.albumsSearchResponse = SearchResponse(items: [
            .album(album),
            .audiobook(audiobook),
        ])

        self.viewModel.query = "spoken word"
        self.viewModel.selectedFilter = .albums
        self.viewModel.searchImmediately()
        await self.waitUntil(
            self.viewModel.filteredItems.count == 2,
            description: "album and audiobook results"
        )

        #expect(self.viewModel.filteredItems.map(\.id) == [
            "album-MPREalbum",
            "audiobook-MPREb_audiobook",
        ])
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
    func editingAfterSubmittedSuggestionReenablesAutocomplete() async {
        let suggestion = SearchSuggestion(query: "daft punk")
        self.mockClient.searchSuggestions = [SearchSuggestion(query: "daft punk random access memories")]

        self.viewModel.selectSuggestion(suggestion)
        self.viewModel.query = "daft punk r"
        self.viewModel.fetchSuggestions()
        await self.waitForSuggestionFetch(query: "daft punk r")

        #expect(self.mockClient.getSearchSuggestionsQueries == ["daft punk r"])
        #expect(self.viewModel.suggestions.count == 1)
        #expect(self.viewModel.showSuggestions == true)
    }

    @Test("Filter chips remain visible after empty filtered search")
    func filterChipsRemainVisibleAfterEmptyFilteredSearch() async {
        self.mockClient.searchResponse = SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: []
        )
        self.viewModel.query = "Versus Music Official"
        self.viewModel.selectedFilter = .artists

        self.viewModel.searchImmediately()
        await self.waitUntil(
            self.viewModel.loadingState == .loaded,
            description: "filtered search to load"
        )

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.filteredItems.isEmpty)
        #expect(self.viewModel.shouldShowFilters)
    }

    @Test("All filter aggregates category-specific search results when mixed search is empty")
    func allFilterAggregatesCategorySpecificSearchResults() async {
        let songsResponse = TestFixtures.makeSearchResponse(
            songCount: 2,
            albumCount: 0,
            artistCount: 0,
            playlistCount: 0
        )
        let albumsResponse = TestFixtures.makeSearchResponse(
            songCount: 0,
            albumCount: 1,
            artistCount: 0,
            playlistCount: 0
        )
        let artistsResponse = TestFixtures.makeSearchResponse(
            songCount: 0,
            albumCount: 0,
            artistCount: 1,
            playlistCount: 0
        )
        let playlistsResponse = TestFixtures.makeSearchResponse(
            songCount: 0,
            albumCount: 0,
            artistCount: 0,
            playlistCount: 1
        )
        let podcastsResponse = SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: [],
            podcastShows: [TestFixtures.makePodcastShow()],
            continuationToken: nil
        )
        let videosResponse = SearchResponse(videos: [Song(
            id: "video",
            title: "Video",
            artists: [],
            videoId: "video",
            musicVideoType: .ugc
        )])
        let profilesResponse = SearchResponse(profiles: [Artist(
            id: "UCprofile",
            name: "Profile",
            profileKind: .profile
        )])
        let episode = PodcastEpisode(
            id: "episode",
            title: "Episode",
            showTitle: "Show",
            showBrowseId: "MPSPPshow",
            description: nil,
            thumbnailURL: nil,
            publishedDate: nil,
            duration: nil,
            durationSeconds: nil,
            playbackProgress: 0,
            isPlayed: false
        )
        let episodesResponse = SearchResponse(podcastEpisodes: [episode])

        self.mockClient.mixedSearchResponse = .empty
        self.mockClient.songsSearchResponse = songsResponse
        self.mockClient.videosSearchResponse = videosResponse
        self.mockClient.albumsSearchResponse = albumsResponse
        self.mockClient.artistsSearchResponse = artistsResponse
        self.mockClient.profilesSearchResponse = profilesResponse
        self.mockClient.featuredPlaylistsSearchResponse = playlistsResponse
        self.mockClient.communityPlaylistsSearchResponse = playlistsResponse
        self.mockClient.podcastsSearchResponse = podcastsResponse
        self.mockClient.episodesSearchResponse = episodesResponse

        self.viewModel.query = "lofi"
        self.viewModel.selectedFilter = .all
        self.viewModel.searchImmediately()
        await self.waitUntil(
            self.viewModel.filteredItems.count == 9,
            description: "all-filter aggregate results"
        )

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.filteredItems.count == 9)
        #expect(self.viewModel.results.allItems.map(\.id) == [
            "song-video-0",
            "song-video-1",
            "video-video",
            "album-MPRE-search-0",
            "artist-UC-search-0",
            "profile-UCprofile",
            "playlist-VL-search-0",
            "podcast-MPSPPLXz2p9test123",
            "episode-episode",
        ])
        #expect(self.viewModel.results.songs.count == 2)
        #expect(self.viewModel.results.videos.count == 1)
        #expect(self.viewModel.results.albums.count == 1)
        #expect(self.viewModel.results.artists.count == 1)
        #expect(self.viewModel.results.profiles.count == 1)
        #expect(self.viewModel.results.playlists.count == 1)
        #expect(self.viewModel.results.podcastShows.count == 1)
        #expect(self.viewModel.results.podcastEpisodes.count == 1)
        #expect(self.mockClient.searchQueries.count == 10)
    }

    @Test("All filter uses mixed response without category fanout when mixed has results")
    func allFilterUsesMixedResponseWithoutCategoryFanout() async {
        let mixedSong = TestFixtures.makeSong(id: "mixed-song", title: "Mixed Song")
        self.mockClient.mixedSearchResponse = SearchResponse(
            songs: [mixedSong],
            albums: [],
            artists: [],
            playlists: []
        )
        self.mockClient.songsSearchResponse = SearchResponse(
            songs: [TestFixtures.makeSong(id: "category-song", title: "Category Song")],
            albums: [],
            artists: [],
            playlists: []
        )
        self.mockClient.albumsSearchResponse = SearchResponse(
            songs: [],
            albums: [TestFixtures.makeAlbum(id: "MPRE-category", title: "Category Album")],
            artists: [],
            playlists: []
        )

        self.viewModel.query = "lofi"
        self.viewModel.selectedFilter = .all
        self.viewModel.searchImmediately()

        await self.waitUntil(
            self.viewModel.results.songs.map(\.id) == ["mixed-song"] && self.viewModel.loadingState == .loaded,
            description: "mixed-only all-filter results"
        )

        #expect(self.viewModel.results.albums.isEmpty)
        #expect(self.viewModel.shouldShowFilters == true)
        #expect(self.mockClient.completedSearchEndpoints == [.mixed])
        #expect(self.mockClient.searchQueries.count == 1)
    }

    @Test("All filter discards delayed fallback category results after query changes")
    func allFilterDiscardsDelayedFallbackCategoryResultsAfterQueryChanges() async {
        let oldCategoryGate = AsyncGate()
        self.mockClient.beforeSearchReturn = { query, endpoint in
            if query == "old", endpoint != .mixed {
                await oldCategoryGate.wait()
            }
        }
        self.mockClient.mixedSearchResponse = .empty
        self.mockClient.songsSearchResponse = SearchResponse(
            songs: [TestFixtures.makeSong(id: "old-category", title: "Old Category")],
            albums: [],
            artists: [],
            playlists: []
        )

        self.viewModel.query = "old"
        self.viewModel.selectedFilter = .all
        self.viewModel.searchImmediately()
        await self.waitUntil(
            self.mockClient.completedSearchEndpoints == [.mixed],
            description: "old mixed empty fallback started"
        )

        self.mockClient.mixedSearchResponse = SearchResponse(
            songs: [TestFixtures.makeSong(id: "new-mixed", title: "New Mixed")],
            albums: [],
            artists: [],
            playlists: []
        )
        self.viewModel.query = "new"
        self.viewModel.searchImmediately()
        await self.waitUntil(
            self.viewModel.results.songs.map(\.id) == ["new-mixed"],
            description: "new mixed-only all-filter results"
        )

        await oldCategoryGate.open()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.viewModel.results.songs.map(\.id) == ["new-mixed"])
        #expect(self.viewModel.results.songs.map(\.id).contains("old-category") == false)
        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("All filter reports error when every aggregate request fails")
    func allFilterReportsErrorWhenEveryAggregateRequestFails() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.viewModel.query = "lofi"
        self.viewModel.selectedFilter = .all
        self.viewModel.searchImmediately()
        await self.waitUntil(
            self.isErrorLoadingState,
            description: "all-filter error"
        )

        guard case let .error(error) = self.viewModel.loadingState else {
            Issue.record("Expected all-filter total failure to surface an error")
            return
        }

        #expect(error.title == "Connection Error")
        #expect(error.isRetryable)
        #expect(self.viewModel.results.isEmpty)
        #expect(self.mockClient.searchQueries.count == 10)
    }

    @Test("Mock reset clears the search continuation return hook")
    func mockResetClearsSearchContinuationHook() {
        self.mockClient.beforeSearchContinuationReturn = { _ in }

        self.mockClient.reset()

        #expect(self.mockClient.beforeSearchContinuationReturn == nil)
        #expect(self.mockClient.getSearchContinuationTokens.isEmpty)
    }

    @Test("Stale pagination cannot append into a newer search")
    func stalePaginationCannotCorruptNewerSearch() async {
        let continuationGate = AsyncGate()
        let oldSong = TestFixtures.makeSong(id: "old", title: "Old")
        let staleSong = TestFixtures.makeSong(id: "stale", title: "Stale")
        let newSong = TestFixtures.makeSong(id: "new", title: "New")

        self.mockClient.songsSearchResponse = SearchResponse(
            songs: [oldSong],
            continuationToken: "old-page-two"
        )
        self.mockClient.searchContinuationResponses["old-page-two"] = SearchResponse(
            songs: [staleSong],
            continuationToken: nil
        )
        self.mockClient.beforeSearchContinuationReturn = { token in
            if token == "old-page-two" {
                await continuationGate.wait()
            }
        }

        self.viewModel.query = "old"
        self.viewModel.selectedFilter = .songs
        await self.waitUntil(
            self.viewModel.loadingState == .loaded && self.viewModel.results.hasMore,
            description: "old paginated search"
        )

        let paginationTask = Task { await self.viewModel.loadMore() }
        await self.waitUntil(
            self.mockClient.getSearchContinuationTokens == ["old-page-two"],
            description: "stale continuation request"
        )
        #expect(self.viewModel.loadingState == .loadingMore)
        #expect(self.viewModel.results.allItems.map(\.id) == ["song-old"])

        self.mockClient.songsSearchResponse = SearchResponse(songs: [newSong])
        self.viewModel.query = "new"
        self.viewModel.searchImmediately()
        await self.waitUntil(
            self.viewModel.results.songs.map(\.id) == ["new"],
            description: "new search results"
        )

        await continuationGate.open()
        await paginationTask.value

        #expect(self.viewModel.results.allItems.map(\.id) == ["song-new"])
        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Load more uses explicit continuation and preserves first occurrence order")
    func loadMoreUsesExplicitContinuationAndDeduplicates() async {
        let first = TestFixtures.makeSong(id: "first", title: "First")
        let second = TestFixtures.makeSong(id: "second", title: "Second")
        self.mockClient.songsSearchResponse = SearchResponse(
            songs: [first],
            continuationToken: "page-two"
        )
        self.mockClient.searchContinuationResponses["page-two"] = SearchResponse(
            songs: [first, second],
            continuationToken: nil
        )

        self.viewModel.query = "ordered"
        self.viewModel.selectedFilter = .songs
        await self.waitUntil(
            self.viewModel.loadingState == .loaded && self.viewModel.results.hasMore,
            description: "initial paginated search"
        )

        await self.viewModel.loadMore()

        #expect(self.mockClient.getSearchContinuationTokens == ["page-two"])
        #expect(self.viewModel.results.allItems.map(\.id) == ["song-first", "song-second"])
        #expect(self.viewModel.results.hasMore == false)
    }
}
