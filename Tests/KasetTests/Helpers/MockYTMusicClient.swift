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
    var searchResponse: SearchResponse = .empty
    var searchSuggestions: [SearchSuggestion] = []
    var libraryPlaylists: [Playlist] = []
    var likedSongs: [Song] = []
    var playlistDetails: [String: PlaylistDetail] = [:]
    var artistDetails: [String: ArtistDetail] = [:]
    var artistSongs: [String: [Song]] = [:]
    var lyricsResponses: [String: Lyrics] = [:]
    var radioQueueSongs: [String: [Song]] = [:]

    // MARK: - Continuation State

    private var _homeContinuationIndex = 0
    private var _exploreContinuationIndex = 0

    var hasMoreHomeSections: Bool {
        self._homeContinuationIndex < self.homeContinuationSections.count
    }

    var hasMoreExploreSections: Bool {
        self._exploreContinuationIndex < self.exploreContinuationSections.count
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
    private(set) var getPlaylistCalled = false
    private(set) var getPlaylistIds: [String] = []
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

    func search(query: String) async throws -> SearchResponse {
        self.searchCalled = true
        self.searchQueries.append(query)
        if let error = shouldThrowError { throw error }
        return self.searchResponse
    }

    func searchSongs(query: String) async throws -> [Song] {
        self.searchCalled = true
        self.searchQueries.append(query)
        if let error = shouldThrowError { throw error }
        return self.searchResponse.songs
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

    func getLikedSongs() async throws -> [Song] {
        self.getLikedSongsCalled = true
        if let error = shouldThrowError { throw error }
        return self.likedSongs
    }

    func getPlaylist(id: String) async throws -> PlaylistDetail {
        self.getPlaylistCalled = true
        self.getPlaylistIds.append(id)
        if let error = shouldThrowError { throw error }
        guard let detail = playlistDetails[id] else {
            throw YTMusicError.parseError(message: "Playlist not found: \(id)")
        }
        return detail
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
        self.searchCalled = false
        self.searchQueries = []
        self.getSearchSuggestionsCalled = false
        self.getSearchSuggestionsQueries = []
        self.getLibraryPlaylistsCalled = false
        self.getLikedSongsCalled = false
        self.getPlaylistCalled = false
        self.getPlaylistIds = []
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
        self.shouldThrowError = nil
    }
}
