import Foundation
@testable import Kaset

/// A mock implementation of YTMusicClientProtocol for testing.
@MainActor
final class MockYTMusicClient: YTMusicClientProtocol {
    // MARK: - Response Stubs

    var homeResponse: HomeResponse = .init(sections: [])
    var homeContinuationSections: [[HomeSection]] = []
    var exploreResponse: HomeResponse = .init(sections: [])
    var exploreContinuationSections: [[HomeSection]] = []
    var chartsResponse: HomeResponse = .init(sections: [])
    var chartsContinuationSections: [[HomeSection]] = []
    var moodsAndGenresResponse: HomeResponse = .init(sections: [])
    var moodsAndGenresContinuationSections: [[HomeSection]] = []
    var newReleasesResponse: HomeResponse = .init(sections: [])
    var newReleasesContinuationSections: [[HomeSection]] = []
    var podcastsSections: [PodcastSection] = []
    var podcastsContinuationSections: [[PodcastSection]] = []
    var searchResponse: SearchResponse = .empty
    var searchContinuationResponses: [SearchResponse] = []
    var searchSuggestions: [SearchSuggestion] = []
    var libraryPlaylists: [Playlist] = []
    var likedSongs: [Song] = []
    var likedSongsContinuationSongs: [[Song]] = []
    var playlistDetails: [String: PlaylistDetail] = [:]
    var playlistContinuationTracks: [String: [[Song]]] = [:]
    var artistDetails: [String: ArtistDetail] = [:]
    var artistSongs: [String: [Song]] = [:]
    var artistSongsResponse: [Song] = []
    var moodCategoryResponse: HomeResponse = .init(sections: [])
    var lyricsResponses: [String: Lyrics] = [:]
    var radioQueueSongs: [String: [Song]] = [:]

    // MARK: - Continuation State

    private var _homeContinuationIndex = 0
    private var _exploreContinuationIndex = 0
    private var _chartsContinuationIndex = 0
    private var _moodsAndGenresContinuationIndex = 0
    private var _newReleasesContinuationIndex = 0
    private var _podcastsContinuationIndex = 0
    private var _likedSongsContinuationIndex = 0
    private var _playlistContinuationIndex = 0
    private var _currentPlaylistId: String?

    var hasMoreHomeSections: Bool {
        self._homeContinuationIndex < self.homeContinuationSections.count
    }

    var hasMoreExploreSections: Bool {
        self._exploreContinuationIndex < self.exploreContinuationSections.count
    }

    var hasMoreChartsSections: Bool {
        self._chartsContinuationIndex < self.chartsContinuationSections.count
    }

    var hasMoreMoodsAndGenresSections: Bool {
        self._moodsAndGenresContinuationIndex < self.moodsAndGenresContinuationSections.count
    }

    var hasMoreNewReleasesSections: Bool {
        self._newReleasesContinuationIndex < self.newReleasesContinuationSections.count
    }

    var hasMorePodcastsSections: Bool {
        self._podcastsContinuationIndex < self.podcastsContinuationSections.count
    }

    var hasMoreLikedSongs: Bool {
        self._likedSongsContinuationIndex < self.likedSongsContinuationSongs.count
    }

    var hasMorePlaylistTracks: Bool {
        guard let playlistId = _currentPlaylistId,
              let continuations = playlistContinuationTracks[playlistId]
        else { return false }
        return self._playlistContinuationIndex < continuations.count
    }

    private var _searchContinuationIndex = 0

    var hasMoreSearchResults: Bool {
        self._searchContinuationIndex < self.searchContinuationResponses.count
    }

    // MARK: - Call Tracking

    private(set) var getHomeCalled = false
    private(set) var getHomeCallCount = 0
    private(set) var getHomeContinuationCalled = false
    private(set) var getHomeContinuationCallCount = 0
    private(set) var getExploreCalled = false
    private(set) var getExploreCallCount = 0
    private(set) var getExploreContinuationCalled = false
    private(set) var getExploreContinuationCallCount = 0
    private(set) var searchCalled = false
    private(set) var searchQueries: [String] = []
    private(set) var getSearchSuggestionsCalled = false
    private(set) var getSearchSuggestionsQueries: [String] = []
    private(set) var getLibraryPlaylistsCalled = false
    private(set) var getLikedSongsCalled = false
    private(set) var getLikedSongsContinuationCalled = false
    private(set) var getLikedSongsContinuationCallCount = 0
    private(set) var getPlaylistCalled = false
    private(set) var getPlaylistIds: [String] = []
    private(set) var getPlaylistContinuationCalled = false
    private(set) var getPlaylistContinuationCallCount = 0
    private(set) var getArtistCalled = false
    private(set) var getArtistIds: [String] = []
    private(set) var getArtistSongsCalled = false
    private(set) var getArtistSongsBrowseIds: [String] = []
    private(set) var rateSongCalled = false
    private(set) var rateSongVideoIds: [String] = []
    private(set) var rateSongRatings: [LikeStatus] = []
    private(set) var editSongLibraryStatusCalled = false
    private(set) var editSongLibraryStatusTokens: [[String]] = []
    private(set) var subscribeToPlaylistCalled = false
    private(set) var subscribeToPlaylistIds: [String] = []
    private(set) var unsubscribeFromPlaylistCalled = false
    private(set) var unsubscribeFromPlaylistIds: [String] = []
    private(set) var subscribeToArtistCalled = false
    private(set) var subscribeToArtistIds: [String] = []
    private(set) var unsubscribeFromArtistCalled = false
    private(set) var unsubscribeFromArtistIds: [String] = []
    private(set) var getLyricsCalled = false
    private(set) var getLyricsVideoIds: [String] = []
    private(set) var getRadioQueueCalled = false
    private(set) var getRadioQueueVideoIds: [String] = []
    private(set) var moodCategoryCalled = false

    // MARK: - Error Simulation

    var shouldThrowError: Error?

    // MARK: - Protocol Implementation

    func getHome() async throws -> HomeResponse {
        self.getHomeCalled = true
        self.getHomeCallCount += 1
        self._homeContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        return self.homeResponse
    }

    func getHomeContinuation() async throws -> [HomeSection]? {
        self.getHomeContinuationCalled = true
        self.getHomeContinuationCallCount += 1
        if let error = shouldThrowError { throw error }
        guard self._homeContinuationIndex < self.homeContinuationSections.count else {
            return nil
        }
        let sections = self.homeContinuationSections[self._homeContinuationIndex]
        self._homeContinuationIndex += 1
        return sections
    }

    func getExplore() async throws -> HomeResponse {
        self.getExploreCalled = true
        self.getExploreCallCount += 1
        self._exploreContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        return self.exploreResponse
    }

    func getExploreContinuation() async throws -> [HomeSection]? {
        self.getExploreContinuationCalled = true
        self.getExploreContinuationCallCount += 1
        if let error = shouldThrowError { throw error }
        guard self._exploreContinuationIndex < self.exploreContinuationSections.count else {
            return nil
        }
        let sections = self.exploreContinuationSections[self._exploreContinuationIndex]
        self._exploreContinuationIndex += 1
        return sections
    }

    func getCharts() async throws -> HomeResponse {
        self._chartsContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        return self.chartsResponse
    }

    func getChartsContinuation() async throws -> [HomeSection]? {
        if let error = shouldThrowError { throw error }
        guard self._chartsContinuationIndex < self.chartsContinuationSections.count else {
            return nil
        }
        let sections = self.chartsContinuationSections[self._chartsContinuationIndex]
        self._chartsContinuationIndex += 1
        return sections
    }

    func getMoodsAndGenres() async throws -> HomeResponse {
        self._moodsAndGenresContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        return self.moodsAndGenresResponse
    }

    func getMoodsAndGenresContinuation() async throws -> [HomeSection]? {
        if let error = shouldThrowError { throw error }
        guard self._moodsAndGenresContinuationIndex < self.moodsAndGenresContinuationSections.count else {
            return nil
        }
        let sections = self.moodsAndGenresContinuationSections[self._moodsAndGenresContinuationIndex]
        self._moodsAndGenresContinuationIndex += 1
        return sections
    }

    func getNewReleases() async throws -> HomeResponse {
        self._newReleasesContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        return self.newReleasesResponse
    }

    func getNewReleasesContinuation() async throws -> [HomeSection]? {
        if let error = shouldThrowError { throw error }
        guard self._newReleasesContinuationIndex < self.newReleasesContinuationSections.count else {
            return nil
        }
        let sections = self.newReleasesContinuationSections[self._newReleasesContinuationIndex]
        self._newReleasesContinuationIndex += 1
        return sections
    }

    func getPodcasts() async throws -> [PodcastSection] {
        self._podcastsContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        return self.podcastsSections
    }

    func getPodcastsContinuation() async throws -> [PodcastSection]? {
        if let error = shouldThrowError { throw error }
        guard self._podcastsContinuationIndex < self.podcastsContinuationSections.count else {
            return nil
        }
        let sections = self.podcastsContinuationSections[self._podcastsContinuationIndex]
        self._podcastsContinuationIndex += 1
        return sections
    }

    func getPodcastShow(browseId _: String) async throws -> PodcastShowDetail {
        if let error = shouldThrowError { throw error }
        return PodcastShowDetail(
            show: PodcastShow(id: "test", title: "Test Show", author: nil, description: nil, thumbnailURL: nil, episodeCount: nil),
            episodes: [],
            continuationToken: nil,
            isSubscribed: false
        )
    }

    func getPodcastEpisodesContinuation(token _: String) async throws -> PodcastEpisodesContinuation {
        if let error = shouldThrowError { throw error }
        return PodcastEpisodesContinuation(episodes: [], continuationToken: nil)
    }

    func search(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        self._searchContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        return self.searchResponse
    }

    func searchSongs(query: String) async throws -> [Song] {
        self.searchCalled = true
        self.searchQueries.append(query)
        if let error = shouldThrowError { throw error }
        return self.searchResponse.songs
    }

    func searchSongsWithPagination(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        self._searchContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        let hasMore = !self.searchContinuationResponses.isEmpty
        return SearchResponse(
            songs: self.searchResponse.songs,
            albums: [],
            artists: [],
            playlists: [],
            continuationToken: hasMore ? "mock-token" : nil
        )
    }

    func searchAlbums(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        self._searchContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        let hasMore = !self.searchContinuationResponses.isEmpty
        return SearchResponse(
            songs: [],
            albums: self.searchResponse.albums,
            artists: [],
            playlists: [],
            continuationToken: hasMore ? "mock-token" : nil
        )
    }

    func searchArtists(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        self._searchContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        let hasMore = !self.searchContinuationResponses.isEmpty
        return SearchResponse(
            songs: [],
            albums: [],
            artists: self.searchResponse.artists,
            playlists: [],
            continuationToken: hasMore ? "mock-token" : nil
        )
    }

    func searchPlaylists(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        self._searchContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        let hasMore = !self.searchContinuationResponses.isEmpty
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: self.searchResponse.playlists,
            continuationToken: hasMore ? "mock-token" : nil
        )
    }

    func searchFeaturedPlaylists(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        self._searchContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        let hasMore = !self.searchContinuationResponses.isEmpty
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: self.searchResponse.playlists,
            continuationToken: hasMore ? "mock-token" : nil
        )
    }

    func searchCommunityPlaylists(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        self._searchContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        let hasMore = !self.searchContinuationResponses.isEmpty
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: self.searchResponse.playlists,
            continuationToken: hasMore ? "mock-token" : nil
        )
    }

    func searchPodcasts(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        self._searchContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        let hasMore = !self.searchContinuationResponses.isEmpty
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: [],
            podcastShows: [],
            continuationToken: hasMore ? "mock-token" : nil
        )
    }

    func getSearchContinuation() async throws -> SearchResponse? {
        if let error = shouldThrowError { throw error }
        guard self._searchContinuationIndex < self.searchContinuationResponses.count else {
            return nil
        }
        let response = self.searchContinuationResponses[self._searchContinuationIndex]
        self._searchContinuationIndex += 1
        return response
    }

    func clearSearchContinuation() {
        self._searchContinuationIndex = 0
    }

    func resetSessionStateForAccountSwitch() {
        self._homeContinuationIndex = 0
        self._exploreContinuationIndex = 0
        self._chartsContinuationIndex = 0
        self._moodsAndGenresContinuationIndex = 0
        self._newReleasesContinuationIndex = 0
        self._podcastsContinuationIndex = 0
        self._likedSongsContinuationIndex = 0
        self._playlistContinuationIndex = 0
        self._searchContinuationIndex = 0
        self._currentPlaylistId = nil
    }

    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion] {
        self.getSearchSuggestionsCalled = true
        self.getSearchSuggestionsQueries.append(query)
        if let error = shouldThrowError { throw error }
        return self.searchSuggestions
    }

    func getLibraryPlaylists() async throws -> [Playlist] {
        self.getLibraryPlaylistsCalled = true
        if let error = shouldThrowError { throw error }
        return self.libraryPlaylists
    }

    func getLibraryContent() async throws -> PlaylistParser.LibraryContent {
        self.getLibraryPlaylistsCalled = true
        if let error = shouldThrowError { throw error }
        return PlaylistParser.LibraryContent(playlists: self.libraryPlaylists, podcastShows: [])
    }

    func getLikedSongs() async throws -> LikedSongsResponse {
        self.getLikedSongsCalled = true
        self._likedSongsContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        let hasMore = !self.likedSongsContinuationSongs.isEmpty
        return LikedSongsResponse(songs: self.likedSongs, continuationToken: hasMore ? "mock-token" : nil)
    }

    func getLikedSongsContinuation() async throws -> LikedSongsResponse? {
        self.getLikedSongsContinuationCalled = true
        self.getLikedSongsContinuationCallCount += 1
        if let error = shouldThrowError { throw error }
        guard self._likedSongsContinuationIndex < self.likedSongsContinuationSongs.count else {
            return nil
        }
        let songs = self.likedSongsContinuationSongs[self._likedSongsContinuationIndex]
        self._likedSongsContinuationIndex += 1
        let hasMore = self._likedSongsContinuationIndex < self.likedSongsContinuationSongs.count
        return LikedSongsResponse(songs: songs, continuationToken: hasMore ? "mock-token-\(self._likedSongsContinuationIndex)" : nil)
    }

    func getPlaylist(id: String) async throws -> PlaylistTracksResponse {
        self.getPlaylistCalled = true
        self.getPlaylistIds.append(id)
        self._currentPlaylistId = id
        self._playlistContinuationIndex = 0
        if let error = shouldThrowError { throw error }
        guard let detail = playlistDetails[id] else {
            throw YTMusicError.parseError(message: "Playlist not found: \(id)")
        }
        let hasContinuation = self.playlistContinuationTracks[id]?.isEmpty == false
        return PlaylistTracksResponse(detail: detail, continuationToken: hasContinuation ? "mock-token" : nil)
    }

    func getPlaylistContinuation() async throws -> PlaylistContinuationResponse? {
        self.getPlaylistContinuationCalled = true
        self.getPlaylistContinuationCallCount += 1
        if let error = shouldThrowError { throw error }
        guard let playlistId = _currentPlaylistId,
              let continuations = playlistContinuationTracks[playlistId],
              self._playlistContinuationIndex < continuations.count
        else {
            return nil
        }
        let tracks = continuations[self._playlistContinuationIndex]
        self._playlistContinuationIndex += 1
        let hasMore = self._playlistContinuationIndex < continuations.count
        return PlaylistContinuationResponse(tracks: tracks, continuationToken: hasMore ? "mock-token-\(self._playlistContinuationIndex)" : nil)
    }

    func getPlaylistAllTracks(playlistId: String) async throws -> [Song] {
        if let error = shouldThrowError { throw error }
        guard let detail = playlistDetails[playlistId] else {
            throw YTMusicError.parseError(message: "Playlist not found: \(playlistId)")
        }
        var allTracks = detail.tracks
        if let continuations = playlistContinuationTracks[playlistId] {
            for batch in continuations {
                allTracks.append(contentsOf: batch)
            }
        }
        return allTracks
    }

    func getArtist(id: String) async throws -> ArtistDetail {
        self.getArtistCalled = true
        self.getArtistIds.append(id)
        if let error = shouldThrowError { throw error }
        guard let detail = artistDetails[id] else {
            throw YTMusicError.parseError(message: "Artist not found: \(id)")
        }
        return detail
    }

    func getArtistSongs(browseId: String, params _: String?) async throws -> [Song] {
        self.getArtistSongsCalled = true
        self.getArtistSongsBrowseIds.append(browseId)
        if let error = shouldThrowError { throw error }
        // Return artistSongsResponse if set, otherwise fall back to dictionary lookup
        if !self.artistSongsResponse.isEmpty {
            return self.artistSongsResponse
        }
        return self.artistSongs[browseId] ?? []
    }

    func rateSong(videoId: String, rating: LikeStatus) async throws {
        self.rateSongCalled = true
        self.rateSongVideoIds.append(videoId)
        self.rateSongRatings.append(rating)
        if let error = shouldThrowError { throw error }
    }

    func editSongLibraryStatus(feedbackTokens: [String]) async throws {
        self.editSongLibraryStatusCalled = true
        self.editSongLibraryStatusTokens.append(feedbackTokens)
        if let error = shouldThrowError { throw error }
    }

    func subscribeToPlaylist(playlistId: String) async throws {
        self.subscribeToPlaylistCalled = true
        self.subscribeToPlaylistIds.append(playlistId)
        if let error = shouldThrowError { throw error }
    }

    func unsubscribeFromPlaylist(playlistId: String) async throws {
        self.unsubscribeFromPlaylistCalled = true
        self.unsubscribeFromPlaylistIds.append(playlistId)
        if let error = shouldThrowError { throw error }
    }

    func subscribeToPodcast(showId _: String) async throws {
        if let error = shouldThrowError { throw error }
    }

    func unsubscribeFromPodcast(showId _: String) async throws {
        if let error = shouldThrowError { throw error }
    }

    func subscribeToArtist(channelId: String) async throws {
        self.subscribeToArtistCalled = true
        self.subscribeToArtistIds.append(channelId)
        if let error = shouldThrowError { throw error }
    }

    func unsubscribeFromArtist(channelId: String) async throws {
        self.unsubscribeFromArtistCalled = true
        self.unsubscribeFromArtistIds.append(channelId)
        if let error = shouldThrowError { throw error }
    }

    func getLyrics(videoId: String) async throws -> Lyrics {
        self.getLyricsCalled = true
        self.getLyricsVideoIds.append(videoId)
        if let error = shouldThrowError { throw error }
        return self.lyricsResponses[videoId] ?? .unavailable
    }

    func getSong(videoId: String) async throws -> Song {
        if let error = shouldThrowError { throw error }
        return Song(
            id: videoId,
            title: "Mock Song",
            artists: [Artist(id: "mock-artist", name: "Mock Artist")],
            videoId: videoId
        )
    }

    func getRadioQueue(videoId: String) async throws -> [Song] {
        self.getRadioQueueCalled = true
        self.getRadioQueueVideoIds.append(videoId)
        if let error = shouldThrowError { throw error }
        return self.radioQueueSongs[videoId] ?? []
    }

    func getMixQueue(playlistId _: String, startVideoId _: String?) async throws -> RadioQueueResult {
        if let error = shouldThrowError { throw error }
        // Return empty by default, can be overridden via radioQueueSongs if needed
        return RadioQueueResult(songs: [], continuationToken: nil)
    }

    func getMixQueueContinuation(continuationToken _: String) async throws -> RadioQueueResult {
        if let error = shouldThrowError { throw error }
        return RadioQueueResult(songs: [], continuationToken: nil)
    }

    func getMoodCategory(browseId _: String, params _: String?) async throws -> HomeResponse {
        self.moodCategoryCalled = true
        if let error = shouldThrowError { throw error }
        return self.moodCategoryResponse
    }

    func fetchAccountsList() async throws -> AccountsListResponse {
        if let error = shouldThrowError { throw error }
        return AccountsListResponse(googleEmail: "test@gmail.com", accounts: [])
    }

    // MARK: - Helper Methods

    /// Resets all call tracking.
    func reset() {
        self.getHomeCalled = false
        self.getHomeCallCount = 0
        self.getHomeContinuationCalled = false
        self.getHomeContinuationCallCount = 0
        self._homeContinuationIndex = 0
        self.getExploreCalled = false
        self.getExploreCallCount = 0
        self.getExploreContinuationCalled = false
        self.getExploreContinuationCallCount = 0
        self._exploreContinuationIndex = 0
        self._chartsContinuationIndex = 0
        self._moodsAndGenresContinuationIndex = 0
        self._newReleasesContinuationIndex = 0
        self._podcastsContinuationIndex = 0
        self._likedSongsContinuationIndex = 0
        self._playlistContinuationIndex = 0
        self._currentPlaylistId = nil
        self.searchCalled = false
        self.searchQueries = []
        self.getSearchSuggestionsCalled = false
        self.getSearchSuggestionsQueries = []
        self.getLibraryPlaylistsCalled = false
        self.getLikedSongsCalled = false
        self.getLikedSongsContinuationCalled = false
        self.getLikedSongsContinuationCallCount = 0
        self.getPlaylistCalled = false
        self.getPlaylistIds = []
        self.getPlaylistContinuationCalled = false
        self.getPlaylistContinuationCallCount = 0
        self.getArtistCalled = false
        self.getArtistIds = []
        self.getArtistSongsCalled = false
        self.getArtistSongsBrowseIds = []
        self.rateSongCalled = false
        self.rateSongVideoIds = []
        self.rateSongRatings = []
        self.editSongLibraryStatusCalled = false
        self.editSongLibraryStatusTokens = []
        self.subscribeToPlaylistCalled = false
        self.subscribeToPlaylistIds = []
        self.unsubscribeFromPlaylistCalled = false
        self.unsubscribeFromPlaylistIds = []
        self.subscribeToArtistCalled = false
        self.subscribeToArtistIds = []
        self.unsubscribeFromArtistCalled = false
        self.unsubscribeFromArtistIds = []
        self.getLyricsCalled = false
        self.getLyricsVideoIds = []
        self.getRadioQueueCalled = false
        self.getRadioQueueVideoIds = []
        self.moodCategoryCalled = false
        self.shouldThrowError = nil
    }
}
