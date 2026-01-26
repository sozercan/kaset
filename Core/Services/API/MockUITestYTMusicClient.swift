import Foundation

/// A mock implementation of YTMusicClientProtocol for UI testing.
/// Returns predictable data from environment variables or defaults.
@MainActor
final class MockUITestYTMusicClient: YTMusicClientProtocol {
    // MARK: - Continuation State

    var hasMoreHomeSections: Bool { false }
    var hasMoreExploreSections: Bool { false }
    var hasMoreChartsSections: Bool { false }
    var hasMoreMoodsAndGenresSections: Bool { false }
    var hasMoreNewReleasesSections: Bool { false }
    var hasMorePodcastsSections: Bool { false }
    var hasMoreLikedSongs: Bool { false }
    var hasMorePlaylistTracks: Bool { false }

    // MARK: - Mock Data

    private let homeSections: [HomeSection]
    private let exploreSections: [HomeSection]
    private let searchResults: SearchResponse
    private let playlists: [Playlist]
    private let likedSongs: [Song]

    init() {
        // Parse mock data from environment variables, or use defaults
        self.homeSections = Self.parseHomeSections() ?? Self.defaultHomeSections()
        self.exploreSections = Self.parseHomeSections() ?? Self.defaultHomeSections()
        self.searchResults = Self.parseSearchResults() ?? Self.defaultSearchResults()
        self.playlists = Self.parsePlaylists() ?? Self.defaultPlaylists()
        self.likedSongs = Self.defaultLikedSongs()
    }

    // MARK: - Protocol Implementation

    func getHome() async throws -> HomeResponse {
        // Simulate network delay
        try? await Task.sleep(for: .milliseconds(100))
        return HomeResponse(sections: self.homeSections)
    }

    func getHomeContinuation() async throws -> [HomeSection]? {
        nil
    }

    func getExplore() async throws -> HomeResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return HomeResponse(sections: self.exploreSections)
    }

    func getExploreContinuation() async throws -> [HomeSection]? {
        nil
    }

    func getCharts() async throws -> HomeResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return HomeResponse(sections: Self.defaultHomeSections())
    }

    func getChartsContinuation() async throws -> [HomeSection]? {
        nil
    }

    func getMoodsAndGenres() async throws -> HomeResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return HomeResponse(sections: Self.defaultHomeSections())
    }

    func getMoodsAndGenresContinuation() async throws -> [HomeSection]? {
        nil
    }

    func getNewReleases() async throws -> HomeResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return HomeResponse(sections: Self.defaultHomeSections())
    }

    func getNewReleasesContinuation() async throws -> [HomeSection]? {
        nil
    }

    func getPodcasts() async throws -> [PodcastSection] {
        try? await Task.sleep(for: .milliseconds(100))
        return []
    }

    func getPodcastsContinuation() async throws -> [PodcastSection]? {
        nil
    }

    func getPodcastShow(browseId _: String) async throws -> PodcastShowDetail {
        try? await Task.sleep(for: .milliseconds(100))
        return PodcastShowDetail(
            show: PodcastShow(id: "test", title: "Test Show", author: nil, description: nil, thumbnailURL: nil, episodeCount: nil),
            episodes: [],
            continuationToken: nil,
            isSubscribed: false
        )
    }

    func getPodcastEpisodesContinuation(token _: String) async throws -> PodcastEpisodesContinuation {
        try? await Task.sleep(for: .milliseconds(100))
        return PodcastEpisodesContinuation(episodes: [], continuationToken: nil)
    }

    func search(query _: String) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return self.searchResults
    }

    func searchSongs(query _: String) async throws -> [Song] {
        try? await Task.sleep(for: .milliseconds(100))
        return self.searchResults.songs
    }

    func searchSongsWithPagination(query _: String) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return SearchResponse(
            songs: self.searchResults.songs,
            albums: [],
            artists: [],
            playlists: [],
            continuationToken: nil
        )
    }

    func searchAlbums(query _: String) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return SearchResponse(
            songs: [],
            albums: self.searchResults.albums,
            artists: [],
            playlists: [],
            continuationToken: nil
        )
    }

    func searchArtists(query _: String) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return SearchResponse(
            songs: [],
            albums: [],
            artists: self.searchResults.artists,
            playlists: [],
            continuationToken: nil
        )
    }

    func searchPlaylists(query _: String) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: self.searchResults.playlists,
            continuationToken: nil
        )
    }

    func searchFeaturedPlaylists(query _: String) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: self.searchResults.playlists,
            continuationToken: nil
        )
    }

    func searchCommunityPlaylists(query _: String) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: self.searchResults.playlists,
            continuationToken: nil
        )
    }

    func searchPodcasts(query _: String) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: [],
            podcastShows: [],
            continuationToken: nil
        )
    }

    func getSearchContinuation() async throws -> SearchResponse? {
        nil
    }

    var hasMoreSearchResults: Bool {
        false
    }

    func clearSearchContinuation() {
        // No-op for mock
    }

    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion] {
        try? await Task.sleep(for: .milliseconds(50))
        return [
            SearchSuggestion(query: "\(query) songs"),
            SearchSuggestion(query: "\(query) artist"),
            SearchSuggestion(query: "\(query) album"),
        ]
    }

    func resetSessionStateForAccountSwitch() {
        // No-op for UI test mock
    }

    func getLibraryPlaylists() async throws -> [Playlist] {
        try? await Task.sleep(for: .milliseconds(100))
        return self.playlists
    }

    func getLibraryContent() async throws -> PlaylistParser.LibraryContent {
        try? await Task.sleep(for: .milliseconds(100))
        return PlaylistParser.LibraryContent(playlists: self.playlists, podcastShows: [])
    }

    func getLikedSongs() async throws -> LikedSongsResponse {
        try? await Task.sleep(for: .milliseconds(100))
        return LikedSongsResponse(songs: self.likedSongs, continuationToken: nil)
    }

    func getLikedSongsContinuation() async throws -> LikedSongsResponse? {
        nil
    }

    func getPlaylist(id: String) async throws -> PlaylistTracksResponse {
        try? await Task.sleep(for: .milliseconds(100))
        let playlist = self.playlists.first { $0.id == id } ?? Playlist(
            id: id,
            title: "Test Playlist",
            description: "A test playlist",
            thumbnailURL: nil,
            trackCount: 10,
            author: "Test User"
        )
        let detail = PlaylistDetail(
            playlist: playlist,
            tracks: Self.defaultSongs(count: 10),
            duration: "30 minutes"
        )
        return PlaylistTracksResponse(detail: detail, continuationToken: nil)
    }

    func getPlaylistContinuation() async throws -> PlaylistContinuationResponse? {
        nil
    }

    func getPlaylistAllTracks(playlistId _: String) async throws -> [Song] {
        try? await Task.sleep(for: .milliseconds(100))
        return Self.defaultSongs(count: 50)
    }

    func getArtist(id: String) async throws -> ArtistDetail {
        try? await Task.sleep(for: .milliseconds(100))
        let artist = Artist(id: id, name: "Test Artist", thumbnailURL: nil)
        return ArtistDetail(
            artist: artist,
            description: "A mock artist for UI testing",
            songs: Self.defaultSongs(count: 5),
            albums: Self.defaultAlbums(count: 3),
            thumbnailURL: nil
        )
    }

    func getArtistSongs(browseId _: String, params _: String?) async throws -> [Song] {
        try? await Task.sleep(for: .milliseconds(100))
        return Self.defaultSongs(count: 20)
    }

    func rateSong(videoId _: String, rating _: LikeStatus) async throws {
        // No-op for UI tests
    }

    func editSongLibraryStatus(feedbackTokens _: [String]) async throws {
        // No-op for UI tests
    }

    func subscribeToPlaylist(playlistId _: String) async throws {
        // No-op for UI tests
    }

    func unsubscribeFromPlaylist(playlistId _: String) async throws {
        // No-op for UI tests
    }

    func subscribeToPodcast(showId _: String) async throws {
        // No-op for UI tests
    }

    func unsubscribeFromPodcast(showId _: String) async throws {
        // No-op for UI tests
    }

    func subscribeToArtist(channelId _: String) async throws {
        // No-op for UI tests
    }

    func unsubscribeFromArtist(channelId _: String) async throws {
        // No-op for UI tests
    }

    func getLyrics(videoId _: String) async throws -> Lyrics {
        try? await Task.sleep(for: .milliseconds(100))
        return Lyrics(
            text: "These are mock lyrics for UI testing.\n\nVerse 1 of the song.\nVerse 2 of the song.",
            source: "Mock Source"
        )
    }

    func getSong(videoId: String) async throws -> Song {
        try? await Task.sleep(for: .milliseconds(100))
        return Song(
            id: videoId,
            title: "Mock Song",
            artists: [Artist(id: "mock-artist", name: "Mock Artist")],
            videoId: videoId
        )
    }

    func getRadioQueue(videoId: String) async throws -> [Song] {
        try? await Task.sleep(for: .milliseconds(100))
        // Return a radio queue based on the seed song
        return (0 ..< 25).map { index in
            Song(
                id: "radio-\(videoId)-\(index)",
                title: "Radio Song \(index + 1)",
                artists: [Artist(id: "radio-artist-\(index % 5)", name: "Radio Artist \(index % 5 + 1)")],
                album: nil,
                duration: TimeInterval(180 + index * 5),
                thumbnailURL: nil,
                videoId: "radio-video-\(videoId)-\(index)"
            )
        }
    }

    func getMixQueue(playlistId: String, startVideoId _: String?) async throws -> RadioQueueResult {
        try? await Task.sleep(for: .milliseconds(100))
        // Return a mix queue based on the playlist ID
        let songs = (0 ..< 50).map { index in
            Song(
                id: "mix-\(playlistId)-\(index)",
                title: "Mix Song \(index + 1)",
                artists: [Artist(id: "mix-artist-\(index % 5)", name: "Mix Artist \(index % 5 + 1)")],
                album: nil,
                duration: TimeInterval(180 + index * 5),
                thumbnailURL: nil,
                videoId: "mix-video-\(playlistId)-\(index)"
            )
        }
        return RadioQueueResult(songs: songs, continuationToken: "mock-continuation-token")
    }

    func getMixQueueContinuation(continuationToken _: String) async throws -> RadioQueueResult {
        try? await Task.sleep(for: .milliseconds(100))
        // Return more songs for infinite mix
        let songs = (50 ..< 75).map { index in
            Song(
                id: "mix-continuation-\(index)",
                title: "Mix Song \(index + 1)",
                artists: [Artist(id: "mix-artist-\(index % 5)", name: "Mix Artist \(index % 5 + 1)")],
                album: nil,
                duration: TimeInterval(180 + index * 5),
                thumbnailURL: nil,
                videoId: "mix-video-continuation-\(index)"
            )
        }
        return RadioQueueResult(songs: songs, continuationToken: nil)
    }

    func getMoodCategory(browseId _: String, params _: String?) async throws -> HomeResponse {
        try? await Task.sleep(for: .milliseconds(100))
        // Return mock mood category content
        let songs = (0 ..< 10).map { index in
            Song(
                id: "mood-song-\(index)",
                title: "Mood Song \(index + 1)",
                artists: [Artist(id: "mood-artist-\(index % 3)", name: "Mood Artist \(index % 3 + 1)")],
                videoId: "mood-video-\(index)"
            )
        }
        let items = songs.map { HomeSectionItem.song($0) }
        let section = HomeSection(id: "mood-section", title: "Top Songs", items: items)
        return HomeResponse(sections: [section])
    }

    func fetchAccountsList() async throws -> AccountsListResponse {
        if UITestConfig.environmentValue(for: UITestConfig.mockAccountLoadingDelayKey) == "true" {
            try? await Task.sleep(for: .milliseconds(800))
        } else {
            try? await Task.sleep(for: .milliseconds(100))
        }

        if let accounts = Self.parseAccounts() {
            return AccountsListResponse(googleEmail: "test@example.com", accounts: accounts)
        }

        // Return default mock account for UI testing
        let primaryAccount = UserAccount(
            id: "primary",
            name: "Test User",
            handle: "@testuser",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )
        return AccountsListResponse(googleEmail: "test@example.com", accounts: [primaryAccount])
    }

    // MARK: - Environment Parsing

    private static func parseHomeSections() -> [HomeSection]? {
        guard let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockHomeSectionsKey),
              let data = jsonString.data(using: .utf8),
              let sections = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }

        return sections.compactMap { dict -> HomeSection? in
            guard let id = dict["id"] as? String,
                  let title = dict["title"] as? String
            else {
                return nil
            }

            let items: [HomeSectionItem] = (dict["items"] as? [[String: Any]])?.compactMap { itemDict in
                guard let itemId = itemDict["id"] as? String,
                      let itemTitle = itemDict["title"] as? String,
                      let videoId = itemDict["videoId"] as? String
                else {
                    return nil
                }
                let artist = itemDict["artist"] as? String ?? "Unknown Artist"
                let song = Song(
                    id: itemId,
                    title: itemTitle,
                    artists: [Artist(id: "mock-artist", name: artist)],
                    videoId: videoId
                )
                return .song(song)
            } ?? []

            return HomeSection(id: id, title: title, items: items)
        }
    }

    private static func parseSearchResults() -> SearchResponse? {
        guard let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockSearchResultsKey),
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let songs = (dict["songs"] as? [[String: Any]])?.compactMap { songDict -> Song? in
            guard let id = songDict["id"] as? String,
                  let title = songDict["title"] as? String,
                  let videoId = songDict["videoId"] as? String
            else {
                return nil
            }
            let artist = songDict["artist"] as? String ?? "Unknown"
            return Song(
                id: id,
                title: title,
                artists: [Artist(id: "mock", name: artist)],
                videoId: videoId
            )
        } ?? []

        return SearchResponse(songs: songs, albums: [], artists: [], playlists: [])
    }

    private static func parsePlaylists() -> [Playlist]? {
        guard let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockPlaylistsKey),
              let data = jsonString.data(using: .utf8),
              let playlists = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }

        return playlists.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let title = dict["title"] as? String
            else {
                return nil
            }
            return Playlist(
                id: id,
                title: title,
                description: nil,
                thumbnailURL: nil,
                trackCount: dict["trackCount"] as? Int,
                author: dict["author"] as? String
            )
        }
    }

    private static func parseAccounts() -> [UserAccount]? {
        guard let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockAccountsKey),
              let data = jsonString.data(using: .utf8),
              let accounts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }

        return accounts.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let isSelected = dict["isSelected"] as? Bool
            else {
                return nil
            }

            let handle = dict["handle"] as? String
            let brandId = dict["brandId"] as? String
            let thumbnailString = dict["thumbnailURL"] as? String
            let thumbnailURL = thumbnailString.flatMap { URL(string: $0) }

            return UserAccount(
                id: id,
                name: name,
                handle: handle,
                brandId: brandId,
                thumbnailURL: thumbnailURL,
                isSelected: isSelected
            )
        }
    }

    // MARK: - Default Data

    private static func defaultHomeSections() -> [HomeSection] {
        [
            HomeSection(
                id: "quick-picks",
                title: "Quick picks",
                items: self.defaultSongs(count: 8).map { .song($0) }
            ),
            HomeSection(
                id: "listen-again",
                title: "Listen again",
                items: self.defaultSongs(count: 6).map { .song($0) }
            ),
            HomeSection(
                id: "recommended",
                title: "Recommended",
                items: self.defaultSongs(count: 10).map { .song($0) }
            ),
        ]
    }

    private static func defaultSearchResults() -> SearchResponse {
        SearchResponse(
            songs: self.defaultSongs(count: 5),
            albums: self.defaultAlbums(count: 2),
            artists: [
                Artist(id: "artist-1", name: "Search Artist 1", thumbnailURL: nil),
                Artist(id: "artist-2", name: "Search Artist 2", thumbnailURL: nil),
            ],
            playlists: self.defaultPlaylists()
        )
    }

    private static func defaultPlaylists() -> [Playlist] {
        (0 ..< 5).map { index in
            Playlist(
                id: "playlist-\(index)",
                title: "My Playlist \(index + 1)",
                description: "A great playlist",
                thumbnailURL: nil,
                trackCount: 10 + index * 5,
                author: "Test User"
            )
        }
    }

    private static func defaultLikedSongs() -> [Song] {
        self.defaultSongs(count: 20)
    }

    private static func defaultSongs(count: Int) -> [Song] {
        (0 ..< count).map { index in
            Song(
                id: "song-\(index)",
                title: "Test Song \(index + 1)",
                artists: [Artist(id: "artist-\(index % 3)", name: "Artist \(index % 3 + 1)")],
                album: Album(
                    id: "album-\(index % 5)",
                    title: "Album \(index % 5 + 1)",
                    artists: nil,
                    thumbnailURL: nil,
                    year: "2024",
                    trackCount: 12
                ),
                duration: TimeInterval(180 + index * 10),
                thumbnailURL: nil,
                videoId: "video-\(index)"
            )
        }
    }

    private static func defaultAlbums(count: Int) -> [Album] {
        (0 ..< count).map { index in
            Album(
                id: "album-\(index)",
                title: "Test Album \(index + 1)",
                artists: [Artist(id: "artist-\(index)", name: "Album Artist \(index + 1)")],
                thumbnailURL: nil,
                year: "2024",
                trackCount: 10 + index
            )
        }
    }
}
