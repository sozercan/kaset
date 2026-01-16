// swiftlint:disable file_length
import CryptoKit
import Foundation
import os

// MARK: - PaginatedContentType

/// Identifies content types that support pagination via continuation tokens.
/// Used internally by YTMusicClient to manage pagination state generically.
enum PaginatedContentType: String, Hashable, Sendable {
    case home = "FEmusic_home"
    case explore = "FEmusic_explore"
    case charts = "FEmusic_charts"
    case moodsAndGenres = "FEmusic_moods_and_genres"
    case newReleases = "FEmusic_new_releases"
    case podcasts = "FEmusic_podcasts"

    /// Display name for logging.
    var displayName: String {
        switch self {
        case .home: "home"
        case .explore: "explore"
        case .charts: "charts"
        case .moodsAndGenres: "moods and genres"
        case .newReleases: "new releases"
        case .podcasts: "podcasts"
        }
    }
}

// MARK: - YTMusicClient

/// Client for making authenticated requests to YouTube Music's internal API.
@MainActor
// swiftlint:disable:next type_body_length
final class YTMusicClient: YTMusicClientProtocol {
    private let authService: AuthService
    private let webKitManager: WebKitManager
    private let session: URLSession
    private let logger = DiagnosticsLogger.api

    /// Provider for the current brand account ID.
    /// Set this after initialization to enable brand account API requests.
    /// Returns nil for primary account, brand ID string for brand accounts.
    var brandIdProvider: (() -> String?)?

    /// YouTube Music API base URL.
    private static let baseURL = "https://music.youtube.com/youtubei/v1"

    /// API key used in requests (extracted from YouTube Music web client).
    private static let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"

    /// Client version for WEB_REMIX.
    private static let clientVersion = "1.20231204.01.00"

    /// Centralized storage for continuation tokens keyed by content type.
    private var continuationTokens: [PaginatedContentType: String] = [:]

    init(authService: AuthService, webKitManager: WebKitManager = .shared) {
        self.authService = authService
        self.webKitManager = webKitManager

        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept-Encoding": "gzip, deflate, br",
        ]
        // Increase connection pool for parallel requests (HTTP/2 multiplexing is automatic)
        configuration.httpMaximumConnectionsPerHost = 6
        // Use shared URL cache for transport-level caching
        configuration.urlCache = URLCache.shared
        configuration.requestCachePolicy = .useProtocolCachePolicy
        // Reduce timeout for faster failure detection
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Generic Pagination Methods

    /// Fetches paginated content for the given content type.
    /// Stores the continuation token for subsequent calls to `getContinuation`.
    private func fetchPaginatedContent(type: PaginatedContentType) async throws -> HomeResponse {
        self.logger.info("Fetching \(type.displayName) page")

        let body: [String: Any] = [
            "browseId": type.rawValue,
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.home)
        let response = HomeResponseParser.parse(data)

        // Store continuation token for progressive loading
        let token = HomeResponseParser.extractContinuationToken(from: data)
        self.continuationTokens[type] = token

        let hasMore = token != nil
        self.logger.info("\(type.displayName.capitalized) page loaded: \(response.sections.count) initial sections, hasMore: \(hasMore)")
        return response
    }

    /// Fetches the next batch of sections for the given content type via continuation.
    /// Returns nil if no more sections are available.
    private func fetchContinuation(type: PaginatedContentType) async throws -> [HomeSection]? {
        guard let token = continuationTokens[type] else {
            self.logger.debug("No \(type.displayName) continuation token available")
            return nil
        }

        self.logger.info("Fetching \(type.displayName) continuation")

        do {
            let continuationData = try await requestContinuation(token)
            let additionalSections = HomeResponseParser.parseContinuation(continuationData)
            self.continuationTokens[type] = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self.continuationTokens[type] != nil

            self.logger.info("\(type.displayName.capitalized) continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch {
            self.logger.warning("Failed to fetch \(type.displayName) continuation: \(error.localizedDescription)")
            self.continuationTokens[type] = nil
            throw error
        }
    }

    /// Checks whether more sections are available for the given content type.
    private func hasMoreSections(for type: PaginatedContentType) -> Bool {
        self.continuationTokens[type] != nil
    }

    // MARK: - Public API Methods (Protocol Conformance)

    /// Fetches the home page content (initial sections only for fast display).
    /// Call `getHomeContinuation` to load additional sections progressively.
    func getHome() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .home)
    }

    /// Fetches the next batch of home sections via continuation.
    /// Returns nil if no more sections are available.
    func getHomeContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .home)
    }

    /// Whether more home sections are available to load.
    var hasMoreHomeSections: Bool {
        self.hasMoreSections(for: .home)
    }

    /// Fetches the explore page content (initial sections only for fast display).
    func getExplore() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .explore)
    }

    /// Fetches the next batch of explore sections via continuation.
    func getExploreContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .explore)
    }

    /// Whether more explore sections are available to load.
    var hasMoreExploreSections: Bool {
        self.hasMoreSections(for: .explore)
    }

    /// Fetches the charts page content (initial sections only for fast display).
    func getCharts() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .charts)
    }

    /// Fetches the next batch of charts sections via continuation.
    func getChartsContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .charts)
    }

    /// Whether more charts sections are available to load.
    var hasMoreChartsSections: Bool {
        self.hasMoreSections(for: .charts)
    }

    /// Fetches the moods and genres page content (initial sections only for fast display).
    func getMoodsAndGenres() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .moodsAndGenres)
    }

    /// Fetches the next batch of moods and genres sections via continuation.
    func getMoodsAndGenresContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .moodsAndGenres)
    }

    /// Whether more moods and genres sections are available to load.
    var hasMoreMoodsAndGenresSections: Bool {
        self.hasMoreSections(for: .moodsAndGenres)
    }

    /// Fetches the new releases page content (initial sections only for fast display).
    func getNewReleases() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .newReleases)
    }

    /// Fetches the next batch of new releases sections via continuation.
    func getNewReleasesContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .newReleases)
    }

    /// Whether more new releases sections are available to load.
    var hasMoreNewReleasesSections: Bool {
        self.hasMoreSections(for: .newReleases)
    }

    /// Fetches the podcasts page content (initial sections only for fast display).
    func getPodcasts() async throws -> [PodcastSection] {
        self.logger.info("Fetching podcasts page")

        let body: [String: Any] = [
            "browseId": PaginatedContentType.podcasts.rawValue,
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.home)
        let sections = PodcastParser.parseDiscovery(data)

        // Store continuation token for progressive loading
        let token = HomeResponseParser.extractContinuationToken(from: data)
        self.continuationTokens[.podcasts] = token

        let hasMore = token != nil
        self.logger.info("Podcasts page loaded: \(sections.count) initial sections, hasMore: \(hasMore)")
        return sections
    }

    /// Fetches the next batch of podcasts sections via continuation.
    func getPodcastsContinuation() async throws -> [PodcastSection]? {
        guard let token = continuationTokens[.podcasts] else {
            self.logger.debug("No podcasts continuation token available")
            return nil
        }

        self.logger.info("Fetching podcasts continuation")

        do {
            let continuationData = try await requestContinuation(token)
            let additionalSections = PodcastParser.parseContinuation(continuationData)
            self.continuationTokens[.podcasts] = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self.continuationTokens[.podcasts] != nil

            self.logger.info("Podcasts continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch {
            self.logger.warning("Failed to fetch podcasts continuation: \(error.localizedDescription)")
            self.continuationTokens[.podcasts] = nil
            throw error
        }
    }

    /// Whether more podcasts sections are available to load.
    var hasMorePodcastsSections: Bool {
        self.hasMoreSections(for: .podcasts)
    }

    /// Fetches details for a podcast show including its episodes.
    func getPodcastShow(browseId: String) async throws -> PodcastShowDetail {
        self.logger.info("Fetching podcast show: \(browseId)")

        let body: [String: Any] = [
            "browseId": browseId,
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.playlist)

        let showDetail = PodcastParser.parseShowDetail(data, showId: browseId)

        self.logger.info("Parsed podcast show '\(showDetail.show.title)' with \(showDetail.episodes.count) episodes")
        return showDetail
    }

    /// Fetches more episodes for a podcast show via continuation.
    func getPodcastEpisodesContinuation(token: String) async throws -> PodcastEpisodesContinuation {
        self.logger.info("Fetching more podcast episodes via continuation")

        let data = try await requestContinuation(token, ttl: APICache.TTL.playlist)
        let continuation = PodcastParser.parseEpisodesContinuation(data)

        self.logger.info("Parsed \(continuation.episodes.count) more episodes")
        return continuation
    }

    /// Makes a continuation request for browse endpoints.
    private func requestContinuation(_ token: String, ttl: TimeInterval? = APICache.TTL.home) async throws -> [String: Any] {
        let body: [String: Any] = [
            "continuation": token,
        ]
        return try await self.request("browse", body: body, ttl: ttl)
    }

    /// Makes a continuation request for next/queue endpoints.
    private func requestContinuation(_ token: String, body additionalBody: [String: Any]) async throws -> [String: Any] {
        var body = additionalBody
        body["continuation"] = token
        return try await self.request("next", body: body)
    }

    /// Searches for content.
    func search(query: String) async throws -> SearchResponse {
        self.logger.info("Searching for: \(query)")

        let body: [String: Any] = [
            "query": query,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Search found \(response.songs.count) songs, \(response.albums.count) albums, \(response.artists.count) artists, \(response.playlists.count) playlists")
        return response
    }

    /// Searches for songs only (filtered search).
    func searchSongs(query: String) async throws -> [Song] {
        self.logger.info("Searching songs only for: \(query)")

        // YouTube Music API params for songs filter
        // Derived from: EgWKAQ (filtered) + II (songs) + AWoMEA4QChADEAQQCRAF (no spelling correction)
        let songsFilterParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

        let body: [String: Any] = [
            "query": query,
            "params": songsFilterParams,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let songs = SearchResponseParser.parseSongsOnly(data)
        self.logger.info("Songs search found \(songs.count) songs")
        return songs
    }

    // MARK: - Filtered Search with Pagination

    /// Filter params for YouTube Music search.
    /// Pattern: EgWKAQ (base) + filter code + AWoMEA4QChADEAQQCRAF (no spelling correction)
    private enum SearchFilterParams {
        static let songs = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        static let albums = "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        static let artists = "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        static let playlists = "EgWKAQIoAWoMEA4QChADEAQQCRAF"
        /// Featured playlists (first-party YouTube Music curated playlists)
        static let featuredPlaylists = "EgeKAQQoADgBagwQDhAKEAMQBBAJEAU="
        /// Community playlists (user-created playlists)
        static let communityPlaylists = "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU="
        /// Podcasts (podcast shows)
        static let podcasts = "EgWKAQJQAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D"
    }

    /// Continuation token for filtered search pagination.
    private var searchContinuationToken: String?

    /// Whether more search results are available to load.
    var hasMoreSearchResults: Bool {
        self.searchContinuationToken != nil
    }

    /// Searches for albums only (filtered search with pagination).
    func searchAlbums(query: String) async throws -> SearchResponse {
        self.logger.info("Searching albums only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.albums,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let (albums, token) = SearchResponseParser.parseAlbumsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Albums search found \(albums.count) albums, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: albums, artists: [], playlists: [], continuationToken: token)
    }

    /// Searches for artists only (filtered search with pagination).
    func searchArtists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching artists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.artists,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let (artists, token) = SearchResponseParser.parseArtistsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Artists search found \(artists.count) artists, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: [], artists: artists, playlists: [], continuationToken: token)
    }

    /// Searches for playlists only (filtered search with pagination).
    func searchPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.playlists,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let (playlists, token) = SearchResponseParser.parsePlaylistsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Playlists search found \(playlists.count) playlists, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: [], artists: [], playlists: playlists, continuationToken: token)
    }

    /// Searches for featured playlists only (YouTube Music curated playlists).
    func searchFeaturedPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching featured playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.featuredPlaylists,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let (playlists, token) = SearchResponseParser.parsePlaylistsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Featured playlists search found \(playlists.count) playlists, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: [], artists: [], playlists: playlists, continuationToken: token)
    }

    /// Searches for community playlists only (user-created playlists).
    func searchCommunityPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching community playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.communityPlaylists,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let (playlists, token) = SearchResponseParser.parsePlaylistsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Community playlists search found \(playlists.count) playlists, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: [], artists: [], playlists: playlists, continuationToken: token)
    }

    /// Searches for podcasts only (podcast shows).
    func searchPodcasts(query: String) async throws -> SearchResponse {
        self.logger.info("Searching podcasts only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.podcasts,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let (podcastShows, token) = SearchResponseParser.parsePodcastsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Podcasts search found \(podcastShows.count) shows, hasMore: \(token != nil)")
        return SearchResponse(
            songs: [],
            albums: [],
            artists: [],
            playlists: [],
            podcastShows: podcastShows,
            continuationToken: token
        )
    }

    /// Searches for songs only with pagination support.
    func searchSongsWithPagination(query: String) async throws -> SearchResponse {
        self.logger.info("Searching songs with pagination for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.songs,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let (songs, token) = SearchResponseParser.parseSongsWithContinuation(data)
        self.searchContinuationToken = token

        self.logger.info("Songs search found \(songs.count) songs, hasMore: \(token != nil)")
        return SearchResponse(songs: songs, albums: [], artists: [], playlists: [], continuationToken: token)
    }

    /// Fetches the next batch of search results via continuation.
    /// Returns nil if no more results are available.
    func getSearchContinuation() async throws -> SearchResponse? {
        guard let token = searchContinuationToken else {
            self.logger.debug("No search continuation token available")
            return nil
        }

        self.logger.info("Fetching search continuation")

        do {
            let continuationData = try await requestContinuation(token, ttl: APICache.TTL.search)
            let response = SearchResponseParser.parseContinuation(continuationData)
            self.searchContinuationToken = response.continuationToken

            self.logger.info("Search continuation loaded: \(response.allItems.count) items, hasMore: \(response.hasMore)")
            return response
        } catch {
            self.logger.warning("Failed to fetch search continuation: \(error.localizedDescription)")
            self.searchContinuationToken = nil
            throw error
        }
    }

    /// Clears the search continuation token.
    func clearSearchContinuation() {
        self.searchContinuationToken = nil
    }

    /// Clears cached continuation/session state when switching accounts.
    func resetSessionStateForAccountSwitch() {
        self.logger.info("Resetting client session state for account switch")
        self.continuationTokens.removeAll()
        self.searchContinuationToken = nil
        self.likedSongsContinuationToken = nil
        self.playlistContinuationToken = nil
    }

    /// Fetches search suggestions for autocomplete.
    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion] {
        guard !query.isEmpty else {
            return []
        }

        self.logger.debug("Fetching search suggestions for: \(query)")

        let body: [String: Any] = [
            "input": query,
        ]

        // No caching for suggestions - they're ephemeral
        let data = try await request("music/get_search_suggestions", body: body)
        let suggestions = SearchSuggestionsParser.parse(data)
        self.logger.debug("Found \(suggestions.count) suggestions")
        return suggestions
    }

    /// Fetches the user's library playlists.
    func getLibraryPlaylists() async throws -> [Playlist] {
        self.logger.info("Fetching library playlists")

        let body: [String: Any] = [
            "browseId": "FEmusic_liked_playlists",
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.library)
        let playlists = PlaylistParser.parseLibraryPlaylists(data)
        self.logger.info("Parsed \(playlists.count) library playlists")
        return playlists
    }

    /// Fetches the user's library content including playlists and podcast shows.
    func getLibraryContent() async throws -> PlaylistParser.LibraryContent {
        self.logger.info("Fetching library content (playlists + podcasts)")

        // Use library_landing to get all content types including podcasts
        let body: [String: Any] = [
            "browseId": "FEmusic_library_landing",
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.library)
        return PlaylistParser.parseLibraryContent(data)
    }

    // MARK: - Liked Songs with Pagination

    /// Continuation token for liked songs pagination.
    private var likedSongsContinuationToken: String?

    /// Whether more liked songs are available to load.
    var hasMoreLikedSongs: Bool {
        self.likedSongsContinuationToken != nil
    }

    /// Fetches the user's liked songs with pagination support.
    /// Uses VLLM (Liked Music playlist) which returns all songs with proper pagination,
    /// unlike FEmusic_liked_videos which is limited to ~13 songs.
    func getLikedSongs() async throws -> LikedSongsResponse {
        self.logger.info("Fetching liked songs via VLLM playlist")

        let body: [String: Any] = [
            "browseId": "VLLM",
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.library)

        // Use playlist parser since VLLM returns playlist format
        let playlistResponse = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: "LM")

        // Store continuation token for pagination
        self.likedSongsContinuationToken = playlistResponse.continuationToken
        let hasMore = playlistResponse.hasMore

        // Convert to LikedSongsResponse format
        let response = LikedSongsResponse(
            songs: playlistResponse.detail.tracks,
            continuationToken: playlistResponse.continuationToken
        )

        self.logger.info("Parsed \(response.songs.count) liked songs, hasMore: \(hasMore)")
        return response
    }

    /// Fetches the next batch of liked songs via continuation.
    /// Returns nil if no more songs are available.
    func getLikedSongsContinuation() async throws -> LikedSongsResponse? {
        guard let token = likedSongsContinuationToken else {
            self.logger.debug("No liked songs continuation token available")
            return nil
        }

        self.logger.info("Fetching liked songs continuation")

        do {
            let continuationData = try await requestContinuation(token)
            // Use playlist continuation parser since VLLM returns playlist format
            let playlistResponse = PlaylistParser.parsePlaylistContinuation(continuationData)
            self.likedSongsContinuationToken = playlistResponse.continuationToken
            let hasMore = playlistResponse.hasMore

            // Convert to LikedSongsResponse format
            let response = LikedSongsResponse(
                songs: playlistResponse.tracks,
                continuationToken: playlistResponse.continuationToken
            )

            self.logger.info("Liked songs continuation loaded: \(response.songs.count) songs, hasMore: \(hasMore)")
            return response
        } catch {
            self.logger.warning("Failed to fetch liked songs continuation: \(error.localizedDescription)")
            self.likedSongsContinuationToken = nil
            throw error
        }
    }

    // MARK: - Playlist with Pagination

    /// Continuation token for playlist tracks pagination.
    private var playlistContinuationToken: String?

    /// Whether more playlist tracks are available to load.
    var hasMorePlaylistTracks: Bool {
        self.playlistContinuationToken != nil
    }

    /// Fetches playlist details including tracks with pagination support.
    func getPlaylist(id: String) async throws -> PlaylistTracksResponse {
        self.logger.info("Fetching playlist: \(id)")

        // Handle different ID formats:
        // - VL... = playlist (already has prefix)
        // - PL... = playlist (needs VL prefix)
        // - RD... = radio/mix (use as-is)
        // - OLAK... = album (use as-is)
        // - MPRE... = album (use as-is)
        let browseId: String = if id.hasPrefix("VL") || id.hasPrefix("RD") || id.hasPrefix("OLAK") || id.hasPrefix("MPRE") || id.hasPrefix("UC") {
            id
        } else if id.hasPrefix("PL") {
            "VL\(id)"
        } else {
            "VL\(id)"
        }

        let body: [String: Any] = [
            "browseId": browseId,
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.playlist)

        let response = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: id)

        // Store continuation token for pagination
        self.playlistContinuationToken = response.continuationToken
        let hasMore = response.hasMore

        self.logger.info("Parsed playlist '\(response.detail.title)' with \(response.detail.tracks.count) tracks, hasMore: \(hasMore)")
        return response
    }

    /// Fetches all tracks for a playlist using the queue endpoint.
    /// This returns all tracks in a single request without pagination.
    /// More reliable for radio playlists (RDCLAK prefix) where continuation doesn't work correctly.
    func getPlaylistAllTracks(playlistId: String) async throws -> [Song] {
        // Strip VL prefix if present since get_queue uses raw playlist ID
        let rawPlaylistId: String = if playlistId.hasPrefix("VL") {
            String(playlistId.dropFirst(2))
        } else {
            playlistId
        }

        self.logger.info("Fetching all playlist tracks via queue: \(rawPlaylistId)")

        let body: [String: Any] = [
            "playlistId": rawPlaylistId,
        ]

        // No caching for queue endpoint - we want fresh results each time
        let data = try await request("music/get_queue", body: body, ttl: nil)

        let tracks = PlaylistParser.parseQueueTracks(data)
        self.logger.info("Fetched \(tracks.count) tracks from queue endpoint")

        return tracks
    }

    /// Fetches the next batch of playlist tracks via continuation.
    /// Returns nil if no more tracks are available.
    func getPlaylistContinuation() async throws -> PlaylistContinuationResponse? {
        guard let token = playlistContinuationToken else {
            self.logger.debug("No playlist continuation token available")
            return nil
        }

        self.logger.info("Fetching playlist continuation")

        do {
            let continuationData = try await requestContinuation(token)
            let response = PlaylistParser.parsePlaylistContinuation(continuationData)
            self.playlistContinuationToken = response.continuationToken
            let hasMore = response.hasMore

            self.logger.info("Playlist continuation loaded: \(response.tracks.count) tracks, hasMore: \(hasMore)")
            return response
        } catch {
            self.logger.warning("Failed to fetch playlist continuation: \(error.localizedDescription)")
            self.playlistContinuationToken = nil
            throw error
        }
    }

    /// Fetches artist details including their songs and albums.
    func getArtist(id: String) async throws -> ArtistDetail {
        self.logger.info("Fetching artist: \(id)")

        let body: [String: Any] = [
            "browseId": id,
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.artist)

        let topKeys = Array(data.keys)
        self.logger.debug("Artist response top-level keys: \(topKeys)")

        let detail = ArtistParser.parseArtistDetail(data, artistId: id)
        self.logger.info("Parsed artist '\(detail.artist.name)' with \(detail.songs.count) songs and \(detail.albums.count) albums")
        return detail
    }

    /// Fetches all songs for an artist using the songs browse endpoint.
    func getArtistSongs(browseId: String, params: String?) async throws -> [Song] {
        self.logger.info("Fetching artist songs: \(browseId)")

        var body: [String: Any] = [
            "browseId": browseId,
        ]

        if let params {
            body["params"] = params
        }

        let data = try await request("browse", body: body, ttl: APICache.TTL.artist)

        let songs = ArtistParser.parseArtistSongs(data)
        self.logger.info("Parsed \(songs.count) artist songs")
        return songs
    }

    // MARK: - Lyrics

    /// Fetches lyrics for a song by video ID.
    /// - Parameter videoId: The video ID of the song
    /// - Returns: Lyrics if available, or Lyrics.unavailable if not
    func getLyrics(videoId: String) async throws -> Lyrics {
        self.logger.info("Fetching lyrics for: \(videoId)")

        // Step 1: Get the lyrics browse ID from the "next" endpoint
        let nextBody: [String: Any] = [
            "videoId": videoId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let nextData = try await request("next", body: nextBody)

        guard let lyricsBrowseId = LyricsParser.extractLyricsBrowseId(from: nextData) else {
            self.logger.info("No lyrics available for: \(videoId)")
            return .unavailable
        }

        // Step 2: Fetch the actual lyrics using the browse ID
        let browseBody: [String: Any] = [
            "browseId": lyricsBrowseId,
        ]

        let browseData = try await request("browse", body: browseBody, ttl: APICache.TTL.lyrics)
        let lyrics = LyricsParser.parse(from: browseData)
        self.logger.info("Fetched lyrics for \(videoId): \(lyrics.isAvailable ? "available" : "unavailable")")
        return lyrics
    }

    // MARK: - Radio Queue

    /// Fetches a radio queue (similar songs) based on a video ID.
    /// Uses the "next" endpoint with a radio playlist ID (RDAMVM prefix).
    /// - Parameter videoId: The seed video ID to base the radio on
    /// - Returns: An array of songs forming the radio queue
    func getRadioQueue(videoId: String) async throws -> [Song] {
        self.logger.info("Fetching radio queue for: \(videoId)")

        // Use RDAMVM prefix to request a radio mix based on the song
        let body: [String: Any] = [
            "videoId": videoId,
            "playlistId": "RDAMVM\(videoId)",
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let data = try await request("next", body: body)
        let result = RadioQueueParser.parse(from: data)
        self.logger.info("Fetched radio queue with \(result.songs.count) songs")
        return result.songs
    }

    /// Fetches a mix queue from a playlist ID (e.g., artist mix "RDEM...").
    /// Uses the "next" endpoint with the provided playlist ID.
    /// - Parameters:
    ///   - playlistId: The mix playlist ID (e.g., "RDEM..." for artist mix)
    ///   - startVideoId: Optional starting video ID
    /// - Returns: RadioQueueResult with songs and continuation token for infinite mix
    func getMixQueue(playlistId: String, startVideoId: String?) async throws -> RadioQueueResult {
        self.logger.info("Fetching mix queue for playlist: \(playlistId)")

        var body: [String: Any] = [
            "playlistId": playlistId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        // Add video ID if provided to start at a specific track
        if let videoId = startVideoId {
            body["videoId"] = videoId
        }

        let data = try await request("next", body: body)
        let result = RadioQueueParser.parse(from: data)
        self.logger.info("Fetched mix queue with \(result.songs.count) songs, hasContinuation: \(result.continuationToken != nil)")
        return result
    }

    /// Fetches more songs for a mix queue using a continuation token.
    /// - Parameter continuationToken: The continuation token from a previous getMixQueue call
    /// - Returns: RadioQueueResult with additional songs and next continuation token
    func getMixQueueContinuation(continuationToken: String) async throws -> RadioQueueResult {
        self.logger.info("Fetching mix queue continuation")

        let body: [String: Any] = [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
        ]

        let data = try await requestContinuation(continuationToken, body: body)
        let result = RadioQueueParser.parseContinuation(from: data)
        self.logger.info("Fetched \(result.songs.count) more songs, hasContinuation: \(result.continuationToken != nil)")
        return result
    }

    // MARK: - Song Metadata

    /// Fetches full song metadata including feedbackTokens for library management.
    /// Uses the `next` endpoint to get track details with library status.
    /// - Parameter videoId: The video ID of the song
    /// - Returns: A Song with full metadata including feedbackTokens and inLibrary status
    func getSong(videoId: String) async throws -> Song {
        self.logger.info("Fetching song metadata: \(videoId)")

        // Use the "next" endpoint which returns track info with feedbackTokens
        let body: [String: Any] = [
            "videoId": videoId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let data = try await request("next", body: body, ttl: APICache.TTL.songMetadata)
        let song = try SongMetadataParser.parse(data, videoId: videoId)
        self.logger.info("Parsed song '\(song.title)' - inLibrary: \(song.isInLibrary ?? false), hasTokens: \(song.feedbackTokens != nil)")
        return song
    }

    // MARK: - Mood/Genre Category

    /// Fetches content for a moods/genres category page.
    /// These are browse pages that return sections of songs/playlists, not playlist tracks.
    /// - Parameters:
    ///   - browseId: The browse ID (e.g., "FEmusic_moods_and_genres_category")
    ///   - params: Optional params for the category (extracted from navigation button)
    /// - Returns: HomeResponse with sections for the category
    func getMoodCategory(browseId: String, params: String?) async throws -> HomeResponse {
        self.logger.info("Fetching mood category: \(browseId)")

        var body: [String: Any] = [
            "browseId": browseId,
        ]

        if let params {
            body["params"] = params
        }

        let data = try await request("browse", body: body, ttl: APICache.TTL.home)
        let response = HomeResponseParser.parse(data)
        self.logger.info("Mood category loaded: \(response.sections.count) sections")
        return response
    }

    // MARK: - Account Management

    /// Fetches the list of available accounts (primary + brand accounts).
    /// Used for account switching functionality.
    /// - Returns: AccountsListResponse containing all available accounts
    /// - Throws: YTMusicError if not authenticated or request fails
    func fetchAccountsList() async throws -> AccountsListResponse {
        self.logger.info("Fetching accounts list")

        let data = try await request("account/accounts_list", body: [:])
        let response = AccountsListParser.parse(data)

        self.logger.info("Accounts list loaded: \(response.accounts.count) accounts")
        return response
    }

    // MARK: - Like/Library Actions

    /// Rates a song (like/dislike/indifferent).
    /// - Parameters:
    ///   - videoId: The video ID of the song to rate
    ///   - rating: The rating to apply (like, dislike, or indifferent to remove rating)
    func rateSong(videoId: String, rating: LikeStatus) async throws {
        self.logger.info("Rating song \(videoId) with \(rating.rawValue)")

        let body: [String: Any] = [
            "target": ["videoId": videoId],
        ]

        // Endpoint varies by rating type
        let endpoint = switch rating {
        case .like:
            "like/like"
        case .dislike:
            "like/dislike"
        case .indifferent:
            "like/removelike"
        }

        _ = try await self.request(endpoint, body: body)
        self.logger.info("Successfully rated song \(videoId)")

        // Invalidate mutation-affected caches in a single pass
        APICache.shared.invalidateMutationCaches()
    }

    /// Adds or removes a song from the user's library.
    /// - Parameter feedbackTokens: Tokens obtained from song metadata (use add token to add, remove token to remove)
    func editSongLibraryStatus(feedbackTokens: [String]) async throws {
        guard !feedbackTokens.isEmpty else {
            self.logger.warning("No feedback tokens provided for library edit")
            return
        }

        self.logger.info("Editing song library status with \(feedbackTokens.count) tokens")

        let body: [String: Any] = [
            "feedbackTokens": feedbackTokens,
        ]

        _ = try await self.request("feedback", body: body)
        self.logger.info("Successfully edited library status")

        // Invalidate mutation-affected caches in a single pass
        APICache.shared.invalidateMutationCaches()
    }

    /// Adds a playlist to the user's library using the like/like endpoint.
    /// This is equivalent to the "Add to Library" action in YouTube Music.
    /// - Parameter playlistId: The playlist ID to add to library
    func subscribeToPlaylist(playlistId: String) async throws {
        self.logger.info("Adding playlist to library: \(playlistId)")

        // Remove VL prefix if present for the API call
        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId

        let body: [String: Any] = [
            "target": ["playlistId": cleanId],
        ]

        _ = try await self.request("like/like", body: body)
        self.logger.info("Successfully added playlist \(playlistId) to library")

        // Invalidate library cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    /// Removes a playlist from the user's library using the like/removelike endpoint.
    /// This is equivalent to the "Remove from Library" action in YouTube Music.
    /// - Parameter playlistId: The playlist ID to remove from library
    func unsubscribeFromPlaylist(playlistId: String) async throws {
        self.logger.info("Removing playlist from library: \(playlistId)")

        // Remove VL prefix if present for the API call
        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId

        let body: [String: Any] = [
            "target": ["playlistId": cleanId],
        ]

        _ = try await self.request("like/removelike", body: body)
        self.logger.info("Successfully removed playlist \(playlistId) from library")

        // Invalidate library cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    // MARK: - Podcast ID Conversion

    /// Converts a podcast show ID (MPSPP prefix) to a playlist ID (PL prefix) for the like/unlike API.
    /// - Podcast show IDs use "MPSPP" + "L" + {idSuffix}, e.g. "MPSPPLXz2p9...".
    /// - The corresponding playlist ID is "PL" + {idSuffix}, e.g. "PLXz2p9...".
    /// - We strip "MPSPP" (5 chars) leaving "LXz2p9...", then prepend "P" to get "PLXz2p9...".
    /// - Parameter showId: The podcast show ID to convert
    /// - Returns: The playlist ID for the like API
    /// - Throws: YTMusicError.invalidInput if the ID format is invalid
    private func convertPodcastShowIdToPlaylistId(_ showId: String) throws -> String {
        guard showId.hasPrefix("MPSPP") else {
            self.logger.warning("ShowId does not have MPSPP prefix, using as-is: \(showId)")
            return showId
        }

        let suffix = String(showId.dropFirst(5)) // "LXz2p9..."

        guard !suffix.isEmpty else {
            self.logger.error("Invalid podcast show ID (missing suffix after MPSPP): \(showId)")
            throw YTMusicError.invalidInput("Invalid podcast show ID: \(showId)")
        }

        guard suffix.hasPrefix("L") else {
            self.logger.error("Invalid podcast show ID (suffix must start with 'L'): \(showId)")
            throw YTMusicError.invalidInput("Invalid podcast show ID format: \(showId)")
        }

        return "P" + suffix // "P" + "LXz2p9..." = "PLXz2p9..."
    }

    /// Subscribes to a podcast show (adds to library).
    /// This uses the like/like endpoint with the playlist ID (PL prefix).
    /// Podcast shows have an MPSPP prefix that maps to PL for the like API.
    /// - Parameter showId: The podcast show ID (MPSPP prefix)
    func subscribeToPodcast(showId: String) async throws {
        self.logger.info("Subscribing to podcast: \(showId)")

        let playlistId = try self.convertPodcastShowIdToPlaylistId(showId)

        let body: [String: Any] = [
            "target": ["playlistId": playlistId],
        ]

        _ = try await self.request("like/like", body: body)
        self.logger.info("Successfully subscribed to podcast \(showId)")

        // Invalidate library cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    /// Unsubscribes from a podcast show (removes from library).
    /// This uses the like/removelike endpoint with the playlist ID (PL prefix).
    /// Podcast shows have an MPSPP prefix that maps to PL for the like API.
    /// - Parameter showId: The podcast show ID (MPSPP prefix)
    func unsubscribeFromPodcast(showId: String) async throws {
        self.logger.info("Unsubscribing from podcast: \(showId)")

        let playlistId = try self.convertPodcastShowIdToPlaylistId(showId)

        let body: [String: Any] = [
            "target": ["playlistId": playlistId],
        ]

        _ = try await self.request("like/removelike", body: body)
        self.logger.info("Successfully unsubscribed from podcast \(showId)")

        // Invalidate library cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    /// Subscribes to an artist by channel ID.
    /// This is equivalent to the "Subscribe" action in YouTube Music.
    /// - Parameter channelId: The channel ID of the artist (e.g., UCxxxxx)
    func subscribeToArtist(channelId: String) async throws {
        self.logger.info("Subscribing to artist: \(channelId)")

        let body: [String: Any] = [
            "channelIds": [channelId],
        ]

        _ = try await self.request("subscription/subscribe", body: body)
        self.logger.info("Successfully subscribed to artist \(channelId)")

        // Invalidate artist cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    /// Unsubscribes from an artist by channel ID.
    /// This is equivalent to the "Unsubscribe" action in YouTube Music.
    /// - Parameter channelId: The channel ID of the artist (e.g., UCxxxxx)
    func unsubscribeFromArtist(channelId: String) async throws {
        self.logger.info("Unsubscribing from artist: \(channelId)")

        let body: [String: Any] = [
            "channelIds": [channelId],
        ]

        _ = try await self.request("subscription/unsubscribe", body: body)
        self.logger.info("Successfully unsubscribed from artist \(channelId)")

        // Invalidate artist cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    // MARK: - Private Methods

    /// Builds authentication headers for API requests.
    private func buildAuthHeaders() async throws -> [String: String] {
        // Log available cookies for debugging auth issues
        let allCookies = await webKitManager.getAllCookies()
        let youtubeCookies = await webKitManager.getCookies(for: "youtube.com")
        self.logger.debug("Building auth headers - total cookies: \(allCookies.count), youtube.com cookies: \(youtubeCookies.count)")

        guard let cookieHeader = await webKitManager.cookieHeader(for: "youtube.com") else {
            self.logger.error("No cookies found for youtube.com domain")
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = await webKitManager.getSAPISID() else {
            self.logger.error("SAPISID cookie not found or expired")
            throw YTMusicError.authExpired
        }

        // Compute SAPISIDHASH
        let origin = WebKitManager.origin
        let timestamp = Int(Date().timeIntervalSince1970)
        let hashInput = "\(timestamp) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let sapisidhash = "\(timestamp)_\(hash)"

        return [
            "Cookie": cookieHeader,
            "Authorization": "SAPISIDHASH \(sapisidhash)",
            "Origin": origin,
            "Referer": origin,
            "Content-Type": "application/json",
            "X-Goog-AuthUser": "0",
            "X-Origin": origin,
        ]
    }

    /// Builds the standard context payload.
    /// Includes `onBehalfOfUser` when a brand account is selected.
    private func buildContext() -> [String: Any] {
        var userDict: [String: Any] = [
            "lockedSafetyMode": false,
        ]

        // Add brand account ID if one is selected
        if let brandId = self.brandIdProvider?() {
            userDict["onBehalfOfUser"] = brandId
            self.logger.debug("Using brand account: \(brandId)")
        } else {
            self.logger.debug("Using primary account (no brand ID)")
        }

        return [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": Self.clientVersion,
                "hl": "en",
                "gl": "US",
                "experimentIds": [],
                "experimentsToken": "",
                "browserName": "Safari",
                "browserVersion": "17.0",
                "osName": "Macintosh",
                "osVersion": "10_15_7",
                "platform": "DESKTOP",
                "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "utcOffsetMinutes": -TimeZone.current.secondsFromGMT() / 60,
            ],
            "user": userDict,
        ]
    }

    /// Makes an authenticated request to the API with optional caching and retry.
    private func request(_ endpoint: String, body: [String: Any], ttl: TimeInterval? = nil) async throws -> [String: Any] {
        // Build request body with context so cache keys reflect the actual request
        var fullBody = body
        fullBody["context"] = self.buildContext()

        // Generate stable cache key from endpoint, full body, and brand account ID
        // Brand ID must be in cache key to prevent returning cached data from other accounts
        let brandId = self.brandIdProvider?() ?? ""
        let cacheKey = APICache.stableCacheKey(endpoint: endpoint, body: fullBody, brandId: brandId)
        self.logger.debug(
            "Request \(endpoint): brandId=\(brandId.isEmpty ? "primary" : brandId), cacheKey=\(cacheKey)")

        // Check cache first
        if ttl != nil, let cached = APICache.shared.get(key: cacheKey) {
            self.logger.debug(
                "Cache hit for \(endpoint) (brandId=\(brandId.isEmpty ? "primary" : brandId))")
            return cached
        }

        // Execute with retry policy
        let json = try await RetryPolicy.default.execute { [self] in
            try await self.performRequest(endpoint, fullBody: fullBody)
        }

        // Cache response if TTL specified
        if let ttl {
            APICache.shared.set(key: cacheKey, data: json, ttl: ttl)
        }

        return json
    }

    /// Performs the actual network request.
    private func performRequest(_ endpoint: String, fullBody: [String: Any]) async throws -> [String:
        Any]
    {
        let urlString = "\(Self.baseURL)/\(endpoint)?key=\(Self.apiKey)&prettyPrint=false"
        guard let url = URL(string: urlString) else {
            throw YTMusicError.unknown(message: "Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Add auth headers
        let headers = try await self.buildAuthHeaders()
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        if let context = fullBody["context"] as? [String: Any],
           let user = context["user"] as? [String: Any]
        {
            let onBehalfOfUser = user["onBehalfOfUser"] as? String
            self.logger.debug(
                "Making request to \(endpoint) (onBehalfOfUser=\(onBehalfOfUser ?? "primary"))")
        } else {
            self.logger.debug("Making request to \(endpoint) (missing context)")
        }

        // Perform network I/O off the main thread
        let result = try await Self.performNetworkRequest(request: request, session: self.session)

        // Handle errors back on main actor
        switch result {
        case let .success(data):
            // Parse JSON synchronously - JSONSerialization is highly optimized
            // and typically completes in <5ms even for large responses.
            // The actual response parsing (in Parsers/) is more expensive
            // but must happen on MainActor anyway for @Observable updates.
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YTMusicError.parseError(message: "Response is not a JSON object")
            }
            return json
        case let .authError(statusCode):
            self.logger.error("Auth error: HTTP \(statusCode)")
            self.authService.sessionExpired()
            throw YTMusicError.authExpired
        case let .httpError(statusCode):
            self.logger.error("API error: HTTP \(statusCode)")
            throw YTMusicError.apiError(
                message: "HTTP \(statusCode)",
                code: statusCode
            )
        case let .networkError(error):
            throw YTMusicError.networkError(underlying: error)
        }
    }

    // MARK: - Nonisolated Network Helper

    /// Result type for network request to avoid throwing across actor boundaries.
    /// Uses Data (which is Sendable) instead of parsed JSON.
    private enum NetworkResult: Sendable {
        case success(Data)
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }

    // Performs network request off the main thread.
    // Returns raw Data to be parsed on the caller's actor.
    // swiftformat:disable:next modifierOrder
    nonisolated private static func performNetworkRequest(
        request: URLRequest,
        session: URLSession
    ) async throws -> NetworkResult {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError(URLError(.badServerResponse))
            }

            // Handle auth errors
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .authError(statusCode: httpResponse.statusCode)
            }

            // Handle other HTTP errors
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                return .httpError(statusCode: httpResponse.statusCode)
            }

            return .success(data)
        } catch {
            return .networkError(error)
        }
    }
}
