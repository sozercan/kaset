// swiftlint:disable file_length
import CryptoKit
import Foundation
import os

enum PaginatedContentType: String, Hashable {
    case home = "FEmusic_home"
    case explore = "FEmusic_explore"
    case charts = "FEmusic_charts"
    case moodsAndGenres = "FEmusic_moods_and_genres"
    case newReleases = "FEmusic_new_releases"
    case podcasts = "FEmusic_podcasts"
    case history = "FEmusic_history"

    var displayName: String {
        switch self {
        case .home: "home"
        case .explore: "explore"
        case .charts: "charts"
        case .moodsAndGenres: "moods and genres"
        case .newReleases: "new releases"
        case .podcasts: "podcasts"
        case .history: "history"
        }
    }
}

@MainActor
// swiftlint:disable:next type_body_length
final class YTMusicClient: YTMusicClientProtocol {
    private let authService: AuthService
    private let webKitManager: WebKitManager
    private let session: URLSession
    private let apiKeyResolver: YTMusicAPIKeyResolver
    private let cache: APICache
    private let logger = DiagnosticsLogger.api

    var brandIdProvider: (() -> String?)?

    var accountScopeProvider: (() -> String?)?

    private static let baseURL = "https://music.youtube.com/youtubei/v1"

    private static let clientVersion = "1.20231204.01.00"

    private var continuationTokens: [PaginatedContentType: String] = [:]
    private var paginationEpochs: [PaginatedContentType: UInt64] = [:]
    private var continuationGeneration = 0
    private var personalizedRecommendationsContinuationToken: String?

    init(
        authService: AuthService,
        webKitManager: WebKitManager = .shared,
        session: URLSession? = nil,
        apiKeyResolver: YTMusicAPIKeyResolver? = nil,
        cache: APICache = .shared
    ) {
        self.authService = authService
        self.webKitManager = webKitManager

        let resolvedSession: URLSession = if let session {
            session
        } else {
            URLSession(configuration: APISessionConfiguration.make())
        }

        self.session = resolvedSession
        self.apiKeyResolver = apiKeyResolver ?? YTMusicAPIKeyResolver(session: resolvedSession)
        self.cache = cache
    }

    private func fetchPaginatedContent(
        type: PaginatedContentType,
        ttl: TimeInterval? = APICache.TTL.home,
        bypassCache: Bool = false
    ) async throws -> HomeResponse {
        self.logger.info("Fetching \(type.displayName) page")

        let paginationEpoch = (self.paginationEpochs[type] ?? 0) &+ 1
        self.paginationEpochs[type] = paginationEpoch
        self.continuationTokens[type] = nil

        let body: [String: Any] = [
            "browseId": type.rawValue,
        ]

        let generation = self.continuationGeneration
        let data = try await request("browse", body: body, ttl: ttl, bypassCache: bypassCache)
        let response = HomeResponseParser.parse(data)

        let token = HomeResponseParser.extractContinuationToken(from: data)
        let isCurrentRequest = generation == self.continuationGeneration
            && self.paginationEpochs[type] == paginationEpoch
        if isCurrentRequest {
            self.continuationTokens[type] = token
        }

        let hasMore = isCurrentRequest && token != nil
        self.logger.info("\(type.displayName.capitalized) page loaded: \(response.sections.count) initial sections, hasMore: \(hasMore)")
        return response
    }

    private func fetchContinuation(type: PaginatedContentType) async throws -> [HomeSection]? {
        guard let token = continuationTokens[type] else {
            self.logger.debug("No \(type.displayName) continuation token available")
            return nil
        }

        self.logger.info("Fetching \(type.displayName) continuation")
        let generation = self.continuationGeneration
        let paginationEpoch = self.paginationEpochs[type] ?? 0

        do {
            let continuationData = try await requestContinuation(token)
            let additionalSections = HomeResponseParser.parseContinuation(continuationData)
            guard generation == self.continuationGeneration,
                  self.paginationEpochs[type] == paginationEpoch
            else {
                self.logger.info("Discarding stale \(type.displayName) continuation")
                return nil
            }
            self.continuationTokens[type] = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self.continuationTokens[type] != nil

            self.logger.info("\(type.displayName.capitalized) continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.logger.warning("Failed to fetch \(type.displayName) continuation: \(error.localizedDescription)")
            if generation == self.continuationGeneration,
               self.paginationEpochs[type] == paginationEpoch
            {
                self.continuationTokens[type] = nil
            }
            throw error
        }
    }

    private func hasMoreSections(for type: PaginatedContentType) -> Bool {
        self.continuationTokens[type] != nil
    }

    func getHome(forceRefresh: Bool) async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .home, bypassCache: forceRefresh)
    }

    func getHomeContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .home)
    }

    var hasMoreHomeSections: Bool {
        self.hasMoreSections(for: .home)
    }

    func getPersonalizedRecommendations() async throws -> HomeResponse {
        self.logger.info("Fetching personalized recommendations")

        let body: [String: Any] = [
            "browseId": PaginatedContentType.home.rawValue,
        ]

        let generation = self.continuationGeneration
        let data = try await self.request("browse", body: body, ttl: APICache.TTL.home)
        let response = HomeResponseParser.parse(data)
        let token = HomeResponseParser.extractContinuationToken(from: data)
        if generation == self.continuationGeneration {
            self.personalizedRecommendationsContinuationToken = token
        }

        let hasMore = generation == self.continuationGeneration && token != nil
        self.logger.info("Personalized recommendations loaded: \(response.sections.count) sections, hasMore: \(hasMore)")
        return response
    }

    func getPersonalizedRecommendationsContinuation() async throws -> [HomeSection]? {
        guard let token = self.personalizedRecommendationsContinuationToken else {
            self.logger.debug("No personalized recommendations continuation token available")
            return nil
        }

        self.logger.info("Fetching personalized recommendations continuation")
        let generation = self.continuationGeneration

        do {
            let continuationData = try await self.requestContinuation(token, authPolicy: .required)
            let additionalSections = HomeResponseParser.parseContinuation(continuationData)
            guard generation == self.continuationGeneration else {
                self.logger.info("Discarding stale personalized recommendations continuation after session reset")
                return nil
            }
            self.personalizedRecommendationsContinuationToken = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self.personalizedRecommendationsContinuationToken != nil

            self.logger.info("Personalized recommendations continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch {
            self.logger.warning("Failed to fetch personalized recommendations continuation: \(error.localizedDescription)")
            self.personalizedRecommendationsContinuationToken = nil
            throw error
        }
    }

    var hasMorePersonalizedRecommendationSections: Bool {
        self.personalizedRecommendationsContinuationToken != nil
    }

    func getExplore() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .explore)
    }

    func getExploreContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .explore)
    }

    var hasMoreExploreSections: Bool {
        self.hasMoreSections(for: .explore)
    }

    func getCharts() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .charts)
    }

    func getChartsContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .charts)
    }

    var hasMoreChartsSections: Bool {
        self.hasMoreSections(for: .charts)
    }

    func getMoodsAndGenres() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .moodsAndGenres)
    }

    func getMoodsAndGenresContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .moodsAndGenres)
    }

    var hasMoreMoodsAndGenresSections: Bool {
        self.hasMoreSections(for: .moodsAndGenres)
    }

    func getNewReleases() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .newReleases)
    }

    func getNewReleasesContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .newReleases)
    }

    var hasMoreNewReleasesSections: Bool {
        self.hasMoreSections(for: .newReleases)
    }

    func getHistory() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .history, ttl: nil)
    }

    func getHistoryContinuation() async throws -> [HomeSection]? {
        guard let continuation = continuationTokens[.history] else {
            self.logger.debug("No history continuation token available")
            return nil
        }

        self.logger.info("Fetching history continuation")
        let generation = self.continuationGeneration

        do {
            let continuationData = try await self.requestContinuation(continuation, authPolicy: .required)
            let additionalSections = HomeResponseParser.parseContinuation(continuationData)
            guard generation == self.continuationGeneration else {
                self.logger.info("Discarding stale history continuation after session reset")
                return nil
            }
            self.continuationTokens[.history] = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self.continuationTokens[.history] != nil

            self.logger.info("History continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch {
            self.logger.warning("Failed to fetch history continuation: \(error.localizedDescription)")
            self.continuationTokens[.history] = nil
            throw error
        }
    }

    var hasMoreHistorySections: Bool {
        self.hasMoreSections(for: .history)
    }

    func getPodcasts() async throws -> [PodcastSection] {
        self.logger.info("Fetching podcasts page")

        let body: [String: Any] = [
            "browseId": PaginatedContentType.podcasts.rawValue,
        ]

        let generation = self.continuationGeneration
        let data = try await request("browse", body: body, ttl: APICache.TTL.home)
        let sections = PodcastParser.parseDiscovery(data)

        let token = HomeResponseParser.extractContinuationToken(from: data)
        if generation == self.continuationGeneration {
            self.continuationTokens[.podcasts] = token
        }

        let hasMore = generation == self.continuationGeneration && token != nil
        self.logger.info("Podcasts page loaded: \(sections.count) initial sections, hasMore: \(hasMore)")
        return sections
    }

    func getPodcastsContinuation() async throws -> [PodcastSection]? {
        guard let token = continuationTokens[.podcasts] else {
            self.logger.debug("No podcasts continuation token available")
            return nil
        }

        self.logger.info("Fetching podcasts continuation")
        let generation = self.continuationGeneration

        do {
            let continuationData = try await requestContinuation(token)
            let additionalSections = PodcastParser.parseContinuation(continuationData)
            guard generation == self.continuationGeneration else {
                self.logger.info("Discarding stale podcasts continuation after session reset")
                return nil
            }
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

    var hasMorePodcastsSections: Bool {
        self.hasMoreSections(for: .podcasts)
    }

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

    func getPodcastEpisodesContinuation(token: String) async throws -> PodcastEpisodesContinuation {
        self.logger.info("Fetching more podcast episodes via continuation")

        let data = try await requestContinuation(token, ttl: APICache.TTL.playlist)
        let continuation = PodcastParser.parseEpisodesContinuation(data)

        self.logger.info("Parsed \(continuation.episodes.count) more episodes")
        return continuation
    }

    private func requestContinuation(
        _ token: String,
        ttl: TimeInterval? = APICache.TTL.home,
        authPolicy: RequestAuthPolicy? = nil
    ) async throws -> [String: Any] {
        let body: [String: Any] = [
            "continuation": token,
        ]
        return try await self.request("browse", body: body, ttl: ttl, authPolicy: authPolicy)
    }

    private func requestContinuation(_ token: String, body additionalBody: [String: Any]) async throws -> [String: Any] {
        var body = additionalBody
        body["continuation"] = token
        return try await self.request("next", body: body)
    }

    func search(query: String) async throws -> SearchResponse {
        self.logger.info("Searching for: \(query)")

        let body: [String: Any] = [
            "query": query,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Search found \(response.allItems.count) ordered results")
        return response
    }

    func searchSongs(query: String) async throws -> [Song] {
        self.logger.info("Searching songs only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.songs,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let songs = SearchResponseParser.parseSongsOnly(data)
        self.logger.info("Songs search found \(songs.count) songs")
        return songs
    }

    private enum SearchFilterParams {
        static let songs = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        static let videos = "EgWKAQIQAWoMEA4QChADEAQQCRAF"
        static let albums = "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        static let artists = "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        static let profiles = "EgWKAQJYAWoMEA4QChADEAQQCRAF"
        static let playlists = "EgWKAQIoAWoMEA4QChADEAQQCRAF"
        static let featuredPlaylists = "EgeKAQQoADgBagwQDhAKEAMQBBAJEAU="
        static let communityPlaylists = "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU="
        static let podcasts = "EgWKAQJQAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D"
        static let episodes = "EgWKAQJIAWoMEA4QChADEAQQCRAF"
    }

    func searchVideos(query: String) async throws -> SearchResponse {
        self.logger.info("Searching videos only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.videos,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)

        self.logger.info("Videos search found \(response.videos.count) videos, hasMore: \(response.hasMore)")
        return response
    }

    func searchAlbums(query: String) async throws -> SearchResponse {
        self.logger.info("Searching albums only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.albums,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Albums search found \(response.albums.count) albums and \(response.audiobooks.count) audiobooks, hasMore: \(response.hasMore)")
        return response
    }

    func searchArtists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching artists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.artists,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Artists search found \(response.artists.count) artists, hasMore: \(response.hasMore)")
        return response
    }

    func searchProfiles(query: String) async throws -> SearchResponse {
        self.logger.info("Searching profiles only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.profiles,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)

        self.logger.info("Profiles search found \(response.profiles.count) profiles, hasMore: \(response.hasMore)")
        return response
    }

    func searchPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.playlists,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Playlists search found \(response.playlists.count) playlists, hasMore: \(response.hasMore)")
        return response
    }

    func searchFeaturedPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching featured playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.featuredPlaylists,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Featured playlists search found \(response.playlists.count) playlists, hasMore: \(response.hasMore)")
        return response
    }

    func searchCommunityPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching community playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.communityPlaylists,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Community playlists search found \(response.playlists.count) playlists, hasMore: \(response.hasMore)")
        return response
    }

    func searchPodcasts(query: String) async throws -> SearchResponse {
        self.logger.info("Searching podcasts only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.podcasts,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Podcasts search found \(response.podcastShows.count) shows, hasMore: \(response.hasMore)")
        return response
    }

    func searchSongsWithPagination(query: String) async throws -> SearchResponse {
        self.logger.info("Searching songs with pagination for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.songs,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Songs search found \(response.songs.count) songs, hasMore: \(response.hasMore)")
        return response
    }

    func searchEpisodes(query: String) async throws -> SearchResponse {
        self.logger.info("Searching podcast episodes only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.episodes,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)

        self.logger.info("Episodes search found \(response.podcastEpisodes.count) episodes, hasMore: \(response.hasMore)")
        return response
    }

    func getSearchContinuation(token: String) async throws -> SearchResponse {
        self.logger.info("Fetching search continuation")
        let generation = self.continuationGeneration

        let body: [String: Any] = [
            "continuation": token,
        ]
        let continuationData = try await request("search", body: body, ttl: APICache.TTL.search)
        guard generation == self.continuationGeneration else {
            self.logger.info("Discarding stale search continuation after session reset")
            throw CancellationError()
        }
        let response = SearchResponseParser.parseContinuation(continuationData)

        self.logger.info("Search continuation loaded: \(response.allItems.count) items, hasMore: \(response.hasMore)")
        return response
    }

    func resetSessionStateForAccountSwitch() {
        self.logger.info("Resetting client session state for account switch")
        self.continuationGeneration &+= 1
        self.cache.invalidateAll()
        self.continuationTokens.removeAll()
        self.paginationEpochs.removeAll()
        self.personalizedRecommendationsContinuationToken = nil
        self.likedSongsContinuationToken = nil
    }

    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion] {
        guard !query.isEmpty else {
            return []
        }

        self.logger.debug("Fetching search suggestions for: \(query)")

        let body: [String: Any] = [
            "input": query,
        ]

        let data = try await request("music/get_search_suggestions", body: body)
        let suggestions = SearchSuggestionsParser.parse(data)
        self.logger.debug("Found \(suggestions.count) suggestions")
        return suggestions
    }

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

    func getLibraryContent() async throws -> PlaylistParser.LibraryContent {
        self.logger.info("Fetching library content")
        let accountScope = self.cacheScope(authenticated: true)

        let landingData = try await self.request(
            "browse",
            body: ["browseId": "FEmusic_library_landing"],
            ttl: APICache.TTL.library
        )

        let landingContent = PlaylistParser.parseLibraryContent(landingData)
        let playlists = try await self.fetchLibraryPlaylists(fallback: landingContent.playlists)
        let (albums, albumsSource) = try await self.fetchLibraryAlbums(fallback: landingContent.albums)
        let (artists, artistsSource) = try await self.fetchLibraryArtists(fallback: landingContent.artists)
        let uploadedSongsPlaylist = try await self.fetchUploadedSongsPlaylist()
        let content = PlaylistParser.LibraryContent(
            playlists: playlists,
            albums: albums,
            artists: artists,
            podcastShows: landingContent.podcastShows,
            uploadedSongsPlaylist: uploadedSongsPlaylist,
            albumsSource: albumsSource,
            artistsSource: artistsSource,
            accountScope: accountScope
        )

        let hasUploadedSongs = content.uploadedSongsPlaylist != nil
        self.logger.info(
            "Parsed \(content.playlists.count) library playlists, \(content.albums.count) albums, \(content.artists.count) artists, \(content.podcastShows.count) podcasts, uploads: \(hasUploadedSongs)"
        )
        return content
    }

    private func fetchLibraryPlaylists(fallback fallbackPlaylists: [Playlist]) async throws -> [Playlist] {
        do {
            let playlistsData = try await self.request(
                "browse",
                body: ["browseId": "FEmusic_liked_playlists"],
                ttl: APICache.TTL.library
            )
            let dedicatedPlaylists = PlaylistParser.parseLibraryPlaylists(playlistsData)

            if dedicatedPlaylists.isEmpty {
                if !fallbackPlaylists.isEmpty {
                    self.logger.warning("Library playlists endpoint returned no playlists, falling back to landing preview")
                }
                return fallbackPlaylists
            }

            return PlaylistParser.mergedLibraryPlaylists(
                dedicated: dedicatedPlaylists,
                fallback: fallbackPlaylists
            )
        } catch {
            self.logger.warning("Library playlists endpoint failed, falling back to landing preview: \(error.localizedDescription)")
            return fallbackPlaylists
        }
    }

    private func fetchLibraryAlbums(
        fallback fallbackAlbums: [Album]
    ) async throws -> ([Album], PlaylistParser.LibraryAlbumsSource) {
        do {
            let albumsData = try await self.request(
                "browse",
                body: ["browseId": "FEmusic_liked_albums"],
                ttl: APICache.TTL.library
            )
            let firstPage = PlaylistParser.parseLibraryAlbumsPage(albumsData)
            if !firstPage.isRecognized,
               firstPage.albums.isEmpty,
               firstPage.nextPages.isEmpty
            {
                self.logger.warning("Saved albums endpoint returned an unrecognized response, falling back to landing preview")
                return (fallbackAlbums, .landingFallback)
            }

            var dedicatedAlbums = firstPage.albums
            var pendingCursors = firstPage.nextPages
            var requestedCursors = Set<String>()
            var completedPagination = firstPage.isRecognized

            while !pendingCursors.isEmpty {
                let cursor = pendingCursors.removeFirst()
                guard requestedCursors.insert(cursor).inserted else {
                    completedPagination = false
                    self.logger.warning("Saved albums pagination repeated a continuation token, keeping partial results")
                    continue
                }

                do {
                    let continuationData = try await self.requestContinuation(
                        cursor,
                        ttl: APICache.TTL.library,
                        authPolicy: .required
                    )
                    let page = PlaylistParser.parseLibraryAlbumsContinuation(continuationData)
                    if !page.isRecognized {
                        completedPagination = false
                        self.logger.warning("Saved albums continuation was only partially recognized, keeping partial results")
                    }
                    dedicatedAlbums = PlaylistParser.mergedLibraryAlbums(
                        dedicated: dedicatedAlbums,
                        fallback: page.albums
                    )
                    pendingCursors.append(contentsOf: page.nextPages)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    completedPagination = false
                    self.logger.warning("Saved albums continuation failed, keeping \(dedicatedAlbums.count) loaded albums: \(error.localizedDescription)")
                }
            }

            if dedicatedAlbums.isEmpty {
                if completedPagination {
                    self.logger.info("Saved albums endpoint returned an authoritative empty collection")
                    return ([], .dedicated)
                }

                return (fallbackAlbums, .partial)
            }

            if completedPagination {
                return (dedicatedAlbums, .dedicated)
            }

            return (
                PlaylistParser.mergedLibraryAlbums(
                    dedicated: dedicatedAlbums,
                    fallback: fallbackAlbums
                ),
                .partial
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.logger.warning("Saved albums endpoint failed, falling back to landing preview: \(error.localizedDescription)")
            return (fallbackAlbums, .landingFallback)
        }
    }

    private func fetchLibraryArtists(
        fallback fallbackArtists: [Artist]
    ) async throws -> ([Artist], PlaylistParser.LibraryArtistsSource) {
        do {
            let artistsData = try await self.request(
                "browse",
                body: [
                    "browseId": "FEmusic_library_corpus_artists",
                    "params": "ggMCCAU=",
                ],
                ttl: APICache.TTL.library
            )
            let artists = PlaylistParser.parseLibraryArtists(artistsData)

            if !artists.isEmpty {
                return (artists, .dedicated)
            }

            self.logger.warning("Library corpus artists endpoint returned no artists, falling back to landing preview")
        } catch {
            self.logger.warning("Library corpus artists endpoint failed, falling back to landing preview: \(error.localizedDescription)")
        }

        return (fallbackArtists, .landingFallback)
    }

    private func fetchUploadedSongsPlaylist() async throws -> Playlist? {
        do {
            let uploadedTracksData = try await self.request(
                "browse",
                body: ["browseId": Playlist.uploadedSongsBrowseID],
                ttl: APICache.TTL.library
            )
            return PlaylistParser.parseUploadedSongsPlaylist(uploadedTracksData)
        } catch {
            self.logger.warning("Uploaded songs endpoint failed, hiding uploads tile: \(error.localizedDescription)")
            return nil
        }
    }

    private var likedSongsContinuationToken: String?

    var hasMoreLikedSongs: Bool {
        self.likedSongsContinuationToken != nil
    }

    func getLikedSongs() async throws -> LikedSongsResponse {
        self.logger.info("Fetching liked songs via VLLM playlist")

        let body: [String: Any] = [
            "browseId": LikedMusicPlaylist.browseID,
        ]

        let generation = self.continuationGeneration
        let data = try await request("browse", body: body, ttl: APICache.TTL.library)

        let playlistResponse = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: LikedMusicPlaylist.id)

        if generation == self.continuationGeneration {
            self.likedSongsContinuationToken = playlistResponse.continuationToken
        }
        let hasMore = generation == self.continuationGeneration && playlistResponse.hasMore

        let response = LikedSongsResponse(
            songs: playlistResponse.detail.tracks,
            continuationToken: playlistResponse.continuationToken
        )

        self.logger.info("Parsed \(response.songs.count) liked songs, hasMore: \(hasMore)")
        return response
    }

    func getLikedSongsContinuation() async throws -> LikedSongsResponse? {
        guard let token = likedSongsContinuationToken else {
            self.logger.debug("No liked songs continuation token available")
            return nil
        }

        self.logger.info("Fetching liked songs continuation")
        let generation = self.continuationGeneration

        do {
            let continuationData = try await requestContinuation(token, authPolicy: .required)
            let playlistResponse = PlaylistParser.parsePlaylistContinuation(continuationData)
            guard generation == self.continuationGeneration else {
                self.logger.info("Discarding stale liked songs continuation after session reset")
                return nil
            }
            self.likedSongsContinuationToken = playlistResponse.continuationToken
            let hasMore = playlistResponse.hasMore

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

    nonisolated static func playlistBrowseId(for id: String) -> String {
        let loadsAsIs = id == Playlist.uploadedSongsBrowseID
            || id.hasPrefix("VL")
            || id.hasPrefix("RD")
            || id.hasPrefix("MPRE")
            || id.hasPrefix("UC")
        return loadsAsIs ? id : "VL\(id)"
    }

    func getPlaylist(id: String) async throws -> PlaylistTracksResponse {
        self.logger.info("Fetching playlist: \(id)")

        let body: [String: Any] = [
            "browseId": Self.playlistBrowseId(for: id),
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.playlist)

        let response = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: id)

        let hasMore = response.hasMore

        self.logger.info("Parsed playlist '\(response.detail.title)' with \(response.detail.tracks.count) tracks, hasMore: \(hasMore)")
        return response
    }

    func getPlaylistAllTracks(playlistId: String) async throws -> [Song] {
        let rawPlaylistId: String = if playlistId.hasPrefix("VL") {
            String(playlistId.dropFirst(2))
        } else {
            playlistId
        }

        self.logger.info("Fetching all playlist tracks via queue: \(rawPlaylistId)")

        let body: [String: Any] = [
            "playlistId": rawPlaylistId,
        ]

        let data = try await request("music/get_queue", body: body, ttl: nil)

        let tracks = PlaylistParser.parseQueueTracks(data)
        self.logger.info("Fetched \(tracks.count) tracks from queue endpoint")

        return tracks
    }

    func getPlaylistContinuation(token: String, requiresAuth: Bool) async throws -> PlaylistContinuationResponse {
        self.logger.info("Fetching playlist continuation")

        do {
            let authPolicy: RequestAuthPolicy? = requiresAuth ? .required : nil
            let continuationData = try await requestContinuation(token, authPolicy: authPolicy)
            let response = PlaylistParser.parsePlaylistContinuation(continuationData)
            let hasMore = response.hasMore

            self.logger.info("Playlist continuation loaded: \(response.tracks.count) tracks, hasMore: \(hasMore)")
            return response
        } catch {
            self.logger.warning("Failed to fetch playlist continuation: \(error.localizedDescription)")
            throw error
        }
    }

    func getArtist(id: String) async throws -> ArtistDetail {
        self.logger.info("Fetching artist: \(id)")

        let body: [String: Any] = [
            "browseId": id,
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.artist)

        let topKeys = Array(data.keys)
        self.logger.debug("Artist response top-level keys: \(topKeys)")

        var detail = ArtistParser.parseArtistDetail(data, artistId: id)

        let songsNeedingDuration = detail.songs.filter { $0.duration == nil }
        if !songsNeedingDuration.isEmpty {
            do {
                let durations = try await self.fetchSongDurations(videoIds: songsNeedingDuration.map(\.videoId))
                let enrichedSongs = detail.songs.map { song -> Song in
                    if song.duration == nil, let duration = durations[song.videoId] {
                        return Song(
                            id: song.id,
                            title: song.title,
                            artists: song.artists,
                            album: song.album,
                            duration: duration,
                            thumbnailURL: song.thumbnailURL,
                            videoId: song.videoId,
                            hasVideo: song.hasVideo,
                            musicVideoType: song.musicVideoType,
                            likeStatus: song.likeStatus,
                            isInLibrary: song.isInLibrary,
                            feedbackTokens: song.feedbackTokens,
                            audioTrackVideoId: song.audioTrackVideoId
                        )
                    }
                    return song
                }
                detail = ArtistDetail(
                    artist: detail.artist,
                    description: detail.description,
                    songs: enrichedSongs,
                    songsSectionTitle: detail.songsSectionTitle,
                    orderedSections: detail.orderedSections,
                    albums: detail.albums,
                    singles: detail.singles,
                    episodes: detail.episodes,
                    playlistsByArtist: detail.playlistsByArtist,
                    relatedArtists: detail.relatedArtists,
                    podcasts: detail.podcasts,
                    moreEndpoints: detail.moreEndpoints,
                    thumbnailURL: detail.thumbnailURL,
                    channelId: detail.channelId,
                    isSubscribed: detail.isSubscribed,
                    subscriberCount: detail.subscriberCount,
                    subscribedButtonText: detail.subscribedButtonText,
                    unsubscribedButtonText: detail.unsubscribedButtonText,
                    monthlyAudience: detail.monthlyAudience,
                    hasMoreSongs: detail.hasMoreSongs,
                    songsBrowseId: detail.songsBrowseId,
                    songsParams: detail.songsParams,
                    mixPlaylistId: detail.mixPlaylistId,
                    mixVideoId: detail.mixVideoId
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.logger.debug("Best-effort duration fetch failed: \(error.localizedDescription)")
            }
        }

        let albumSections = detail.orderedSections.compactMap {
            if case let .albums(albums) = $0.content {
                albums
            } else {
                nil
            }
        }
        let playlistSections = detail.orderedSections.compactMap {
            if case let .playlists(playlists) = $0.content {
                playlists
            } else {
                nil
            }
        }
        let artistSections = detail.orderedSections.compactMap {
            if case let .artists(artists) = $0.content {
                artists
            } else {
                nil
            }
        }
        let artistCount = artistSections.reduce(0) { $0 + $1.count }
        let playlistCount = playlistSections.reduce(0) { $0 + $1.count }
        let albumCount = albumSections.reduce(0) { $0 + $1.count }
        self.logger.info("Parsed artist '\(detail.artist.name)' with \(detail.songs.count) songs, \(albumCount) albums across \(albumSections.count) album sections, \(playlistCount) playlists across \(playlistSections.count) playlist sections and \(artistCount) related artists across \(artistSections.count) artist sections")
        return detail
    }

    private func fetchSongDurations(videoIds: [String]) async throws -> [String: TimeInterval] {
        guard !videoIds.isEmpty else { return [:] }

        let body: [String: Any] = [
            "videoIds": videoIds,
        ]

        let data = try await request("music/get_queue", body: body, ttl: APICache.TTL.artist)

        var durations: [String: TimeInterval] = [:]
        if let queueDatas = data["queueDatas"] as? [[String: Any]] {
            for queueData in queueDatas {
                guard let content = queueData["content"] as? [String: Any] else { continue }
                let renderer: [String: Any]? = if let direct = content["playlistPanelVideoRenderer"] as? [String: Any] {
                    direct
                } else if let wrapper = content["playlistPanelVideoWrapperRenderer"] as? [String: Any],
                          let primary = wrapper["primaryRenderer"] as? [String: Any],
                          let wrapped = primary["playlistPanelVideoRenderer"] as? [String: Any]
                {
                    wrapped
                } else {
                    nil
                }
                if let renderer,
                   let videoId = renderer["videoId"] as? String,
                   let lengthText = renderer["lengthText"] as? [String: Any],
                   let runs = lengthText["runs"] as? [[String: Any]],
                   let durationText = runs.first?["text"] as? String,
                   let duration = ParsingHelpers.parseDuration(durationText)
                {
                    durations[videoId] = duration
                }
            }
        }

        self.logger.debug("Fetched durations for \(durations.count)/\(videoIds.count) songs")
        return durations
    }

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

    func getArtistDiscography(browseId: String, params: String?) async throws -> [Album] {
        self.logger.info("Fetching artist discography: \(browseId)")

        var body: [String: Any] = [
            "browseId": browseId,
        ]
        if let params {
            body["params"] = params
        }

        let data = try await request("browse", body: body, ttl: APICache.TTL.artist)
        let albums = ArtistParser.parseArtistDiscography(data)
        self.logger.info("Parsed \(albums.count) discography albums")
        return albums
    }

    func getArtistEpisodesList(browseId: String, params: String?) async throws -> [ArtistEpisode] {
        self.logger.info("Fetching artist episodes list: \(browseId)")

        var body: [String: Any] = [
            "browseId": browseId,
        ]
        if let params {
            body["params"] = params
        }

        let data = try await request("browse", body: body, ttl: APICache.TTL.artist)
        let episodes = ArtistParser.parseArtistEpisodesGrid(data)
        self.logger.info("Parsed \(episodes.count) episodes")
        return episodes
    }

    func getLyrics(videoId: String) async throws -> Lyrics {
        self.logger.info("Fetching lyrics for: \(videoId)")

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

        let browseBody: [String: Any] = [
            "browseId": lyricsBrowseId,
        ]

        let browseData = try await request("browse", body: browseBody, ttl: APICache.TTL.lyrics)
        let lyrics = LyricsParser.parse(from: browseData)
        self.logger.info("Fetched lyrics for \(videoId): \(lyrics.isAvailable ? "available" : "unavailable")")
        return lyrics
    }

    func getTimedLyrics(videoId: String) async throws -> LyricResult {
        self.logger.info("Fetching timed lyrics for: \(videoId)")

        let nextBody: [String: Any] = [
            "videoId": videoId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let nextData = try await request("next", body: nextBody)

        if let synced = LyricsParser.extractTimedLyrics(from: nextData) {
            self.logger.info("Found timed lyrics for \(videoId): \(synced.lines.count) lines")
            return .synced(synced)
        }

        if let lyricsBrowseId = LyricsParser.extractLyricsBrowseId(from: nextData) {
            let browseBody: [String: Any] = [
                "browseId": lyricsBrowseId,
            ]
            let browseData = try await request("browse", body: browseBody, ttl: APICache.TTL.lyrics)
            let lyrics = LyricsParser.parse(from: browseData)
            if lyrics.isAvailable {
                self.logger.info("Fell back to plain lyrics for \(videoId)")
                return .plain(lyrics)
            }
        }

        self.logger.info("No timed lyrics available for: \(videoId)")
        return .unavailable
    }

    func getRadioQueue(videoId: String) async throws -> [Song] {
        self.logger.info("Fetching radio queue for: \(videoId)")

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

    func getMixQueue(playlistId: String, startVideoId: String?) async throws -> RadioQueueResult {
        self.logger.info("Fetching mix queue for playlist: \(playlistId)")

        var body: [String: Any] = [
            "playlistId": playlistId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        if let videoId = startVideoId {
            body["videoId"] = videoId
        }

        let data = try await request("next", body: body)
        let result = RadioQueueParser.parse(from: data)
        self.logger.info("Fetched mix queue with \(result.songs.count) songs, hasContinuation: \(result.continuationToken != nil)")
        return result
    }

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

    func getSong(videoId: String) async throws -> Song {
        self.logger.info("Fetching song metadata: \(videoId)")

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

    func fetchAccountsList(allowGuestMode: Bool) async throws -> AccountsListResponse {
        self.logger.info("Fetching accounts list")

        let data = try await request(
            "account/accounts_list",
            body: [:],
            authPolicy: .required,
            allowGuestAuthentication: allowGuestMode
        )
        let response = AccountsListParser.parse(data)

        self.logger.info("Accounts list loaded: \(response.accounts.count) accounts")
        return response
    }

    func rateSong(videoId: String, rating: LikeStatus) async throws {
        self.logger.info("Rating song \(videoId) with \(rating.rawValue)")

        let body: [String: Any] = [
            "target": ["videoId": videoId],
        ]

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

        self.cache.invalidateMutationCaches()
    }

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

        self.cache.invalidateMutationCaches()
    }

    func subscribeToPlaylist(playlistId: String) async throws {
        self.logger.info("Adding playlist to library: \(playlistId)")

        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId

        let body: [String: Any] = [
            "target": ["playlistId": cleanId],
        ]

        _ = try await self.request("like/like", body: body)
        self.logger.info("Successfully added playlist \(playlistId) to library")

        self.cache.invalidate(matching: "browse:")
    }

    func deletePlaylist(playlistId: String) async throws {
        self.logger.info("Deleting playlist: \(playlistId)")

        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId

        let body: [String: Any] = [
            "playlistId": cleanId,
        ]

        _ = try await self.request("playlist/delete", body: body)
        self.logger.info("Successfully deleted playlist \(playlistId)")

        self.cache.invalidateMutationCaches()
    }

    func getAddToPlaylistOptions(videoId: String) async throws -> AddToPlaylistMenu {
        self.logger.info("Fetching add-to-playlist options for song \(videoId)")

        let body: [String: Any] = [
            "videoIds": [videoId],
        ]

        let data = try await self.request("playlist/get_add_to_playlist", body: body, ttl: APICache.TTL.library)
        let menu = PlaylistParser.parseAddToPlaylistMenu(data)
        self.logger.info("Parsed \(menu.options.count) add-to-playlist options")
        return menu
    }

    func createPlaylist(
        title: String,
        description: String?,
        privacyStatus: PlaylistPrivacyStatus,
        videoIds: [String]
    ) async throws -> String {
        self.logger.info("Creating playlist: \(title, privacy: .public)")

        var body: [String: Any] = [
            "title": title,
            "privacyStatus": privacyStatus.rawValue,
        ]

        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["description"] = description
        }

        if !videoIds.isEmpty {
            body["videoIds"] = videoIds
        }

        let data = try await self.request("playlist/create", body: body)
        guard let playlistId = PlaylistParser.parseCreatedPlaylistId(data) else {
            throw YTMusicError.parseError(message: "Missing playlist ID in create playlist response")
        }

        self.logger.info("Successfully created playlist \(playlistId, privacy: .public)")
        self.cache.invalidateMutationCaches()
        return playlistId
    }

    func addSongToPlaylist(videoId: String, playlistId: String) async throws {
        self.logger.info("Adding song \(videoId) to playlist \(playlistId)")

        let cleanPlaylistId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let body: [String: Any] = [
            "playlistId": cleanPlaylistId,
            "actions": [[
                "action": "ACTION_ADD_VIDEO",
                "addedVideoId": videoId,
            ]],
        ]

        _ = try await self.request("browse/edit_playlist", body: body)
        self.logger.info("Successfully added song \(videoId) to playlist \(playlistId)")

        self.cache.invalidateMutationCaches()
    }

    func removeSongFromPlaylist(videoId: String, setVideoId: String, playlistId: String) async throws {
        self.logger.info("Removing song \(videoId) from playlist \(playlistId)")

        let cleanPlaylistId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let body: [String: Any] = [
            "playlistId": cleanPlaylistId,
            "actions": [[
                "action": "ACTION_REMOVE_VIDEO",
                "removedVideoId": videoId,
                "setVideoId": setVideoId,
            ]],
        ]

        _ = try await self.request("browse/edit_playlist", body: body)
        self.logger.info("Successfully removed song \(videoId) from playlist \(playlistId)")

        self.cache.invalidateMutationCaches()
    }

    func unsubscribeFromPlaylist(playlistId: String) async throws {
        self.logger.info("Removing playlist from library: \(playlistId)")

        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId

        let body: [String: Any] = [
            "target": ["playlistId": cleanId],
        ]

        _ = try await self.request("like/removelike", body: body)
        self.logger.info("Successfully removed playlist \(playlistId) from library")

        self.cache.invalidate(matching: "browse:")
    }

    private func convertPodcastShowIdToPlaylistId(_ showId: String) throws -> String {
        guard showId.hasPrefix("MPSPP") else {
            self.logger.warning("ShowId does not have MPSPP prefix, using as-is: \(showId)")
            return showId
        }

        let suffix = String(showId.dropFirst(5))

        guard !suffix.isEmpty else {
            self.logger.error("Invalid podcast show ID (missing suffix after MPSPP): \(showId)")
            throw YTMusicError.invalidInput("Invalid podcast show ID: \(showId)")
        }

        guard suffix.hasPrefix("L") else {
            self.logger.error("Invalid podcast show ID (suffix must start with 'L'): \(showId)")
            throw YTMusicError.invalidInput("Invalid podcast show ID format: \(showId)")
        }

        return "P" + suffix
    }

    func subscribeToPodcast(showId: String) async throws {
        self.logger.info("Subscribing to podcast: \(showId)")

        let playlistId = try self.convertPodcastShowIdToPlaylistId(showId)

        let body: [String: Any] = [
            "target": ["playlistId": playlistId],
        ]

        _ = try await self.request("like/like", body: body)
        self.logger.info("Successfully subscribed to podcast \(showId)")

        self.cache.invalidate(matching: "browse:")
    }

    func unsubscribeFromPodcast(showId: String) async throws {
        self.logger.info("Unsubscribing from podcast: \(showId)")

        let playlistId = try self.convertPodcastShowIdToPlaylistId(showId)

        let body: [String: Any] = [
            "target": ["playlistId": playlistId],
        ]

        self.logger.debug("Calling like/removelike with playlistId=\(playlistId)")
        _ = try await self.request("like/removelike", body: body)
        self.logger.info("Successfully unsubscribed from podcast \(showId)")

        self.cache.invalidate(matching: "browse:")
    }

    func subscribeToArtist(channelId: String) async throws {
        self.logger.info("Subscribing to artist: \(channelId)")

        let body: [String: Any] = [
            "channelIds": [channelId],
        ]

        _ = try await self.request("subscription/subscribe", body: body)
        self.logger.info("Successfully subscribed to artist \(channelId)")

        self.cache.invalidate(matching: "browse:")
    }

    func unsubscribeFromArtist(channelId: String) async throws {
        self.logger.info("Unsubscribing from artist: \(channelId)")

        let body: [String: Any] = [
            "channelIds": [channelId],
        ]

        _ = try await self.request("subscription/unsubscribe", body: body)
        self.logger.info("Successfully unsubscribed from artist \(channelId)")

        self.cache.invalidate(matching: "browse:")
    }

    private enum RequestAuthPolicy {
        case optional
        case required
    }

    private struct RequestAuthHeaders {
        let headers: [String: String]
        let authenticated: Bool
        let authIdentityGeneration: UInt64?
        let allowsGuestAuthentication: Bool
    }

    private func authPolicy(forEndpoint endpoint: String, body: [String: Any]) -> RequestAuthPolicy {
        if Self.authRequiredActionEndpoints.contains(endpoint) {
            return .required
        }

        if endpoint == "browse", let browseId = body["browseId"] as? String {
            if Self.authRequiredBrowseIds.contains(browseId)
                || browseId == LikedMusicPlaylist.browseID
                || browseId.hasPrefix("MPLAUC")
                || browseId == Playlist.uploadedSongsBrowseID
            {
                return .required
            }
        }

        return .optional
    }

    private func buildRequestHeaders(
        authPolicy: RequestAuthPolicy,
        allowGuestAuthentication: Bool
    ) async throws -> RequestAuthHeaders {
        let canAuthenticate = self.canUseAuthenticatedSession(allowGuestAuthentication: allowGuestAuthentication)
        if canAuthenticate {
            let authIdentityGeneration = self.authService.accountIdentityGeneration
            do {
                let headers = try await self.buildAuthHeaders()
                try self.validateAuthIdentity(
                    authenticated: true,
                    generation: authIdentityGeneration,
                    allowGuestAuthentication: allowGuestAuthentication
                )
                return RequestAuthHeaders(
                    headers: headers,
                    authenticated: true,
                    authIdentityGeneration: authIdentityGeneration,
                    allowsGuestAuthentication: allowGuestAuthentication
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                try self.validateAuthIdentity(
                    authenticated: true,
                    generation: authIdentityGeneration,
                    allowGuestAuthentication: allowGuestAuthentication
                )
                self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                throw YTMusicError.authExpired
            }
        } else if authPolicy == .required {
            throw YTMusicError.notAuthenticated
        }

        return RequestAuthHeaders(
            headers: self.buildUnauthenticatedHeaders(),
            authenticated: false,
            authIdentityGeneration: nil,
            allowsGuestAuthentication: false
        )
    }

    private func buildUnauthenticatedHeaders() -> [String: String] {
        let origin = WebKitManager.origin
        return [
            "Origin": origin,
            "Referer": origin,
            "Content-Type": "application/json",
        ]
    }

    private func cacheScope(authenticated: Bool) -> String {
        guard authenticated else { return "guest" }
        if let accountScope = self.accountScopeProvider?(), !accountScope.isEmpty {
            return accountScope
        }
        let brandId = self.brandIdProvider?() ?? ""
        return brandId.isEmpty ? "primary" : brandId
    }

    private static let authRequiredBrowseIds: Set<String> = [
        "FEmusic_liked_playlists",
        "FEmusic_liked_albums",
        "FEmusic_liked_videos",
        "FEmusic_history",
        "FEmusic_library_landing",
        "FEmusic_library_artists",
        "FEmusic_library_corpus_artists",
        "FEmusic_library_corpus_track_artists",
        "FEmusic_library_songs",
        "FEmusic_recently_played",
        "FEmusic_offline",
        "FEmusic_library_privately_owned_landing",
        "FEmusic_library_privately_owned_tracks",
        "FEmusic_library_privately_owned_albums",
        "FEmusic_library_privately_owned_artists",
    ]

    private static let authRequiredActionEndpoints: Set<String> = [
        "like/like",
        "like/dislike",
        "like/removelike",
        "feedback",
        "subscription/subscribe",
        "subscription/unsubscribe",
        "playlist/get_add_to_playlist",
        "browse/edit_playlist",
        "playlist/create",
        "playlist/delete",
        "account/account_menu",
        "account/accounts_list",
        "notification/get_notification_menu",
        "stats/watchtime",
    ]

    private func buildAuthHeaders() async throws -> [String: String] {
        let authMaterial = await webKitManager.authMaterial(for: "youtube.com")
        self.logger.debug("Building auth headers - total cookies: \(authMaterial.totalCookieCount), youtube.com cookies: \(authMaterial.domainCookieCount)")

        guard let cookieHeader = authMaterial.cookieHeader else {
            self.logger.error("No cookies found for youtube.com domain")
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = authMaterial.sapisid else {
            self.logger.error("SAPISID cookie not found or expired")
            throw YTMusicError.authExpired
        }

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

    private func buildContext(authenticated: Bool) -> [String: Any] {
        var userDict: [String: Any] = [
            "lockedSafetyMode": false,
        ]

        if authenticated, let brandId = self.brandIdProvider?() {
            userDict["onBehalfOfUser"] = brandId
            self.logger.debug("Using brand account: \(brandId)")
        } else if authenticated {
            self.logger.debug("Using primary account (no brand ID)")
        } else {
            self.logger.debug("Using signed-out YouTube Music context")
        }

        return [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": Self.clientVersion,
                "hl": SettingsManager.shared.contentLanguage.apiLanguageCode,
                "gl": "US",
                "experimentIds": [],
                "experimentsToken": "",
                "browserName": "Safari",
                "browserVersion": "17.0",
                "osName": "Macintosh",
                "osVersion": "10_15_7",
                "platform": "DESKTOP",
                "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "utcOffsetMinutes": InnerTubeSupport.utcOffsetMinutes(for: .current),
            ],
            "user": userDict,
        ]
    }

    private func request(
        _ endpoint: String,
        body: [String: Any],
        ttl: TimeInterval? = nil,
        bypassCache: Bool = false,
        authPolicy explicitAuthPolicy: RequestAuthPolicy? = nil,
        allowGuestAuthentication: Bool = false
    ) async throws -> [String: Any] {
        let cacheGeneration = self.cache.generation
        let cacheWriteTicket = ttl.flatMap { _ in
            self.cache.prepareWrite(cacheGeneration: cacheGeneration)
        }
        defer {
            if let cacheWriteTicket {
                self.cache.finishWrite(cacheWriteTicket)
            }
        }
        let authPolicy = explicitAuthPolicy ?? self.authPolicy(forEndpoint: endpoint, body: body)
        let requestAuth = try await self.buildRequestHeaders(
            authPolicy: authPolicy,
            allowGuestAuthentication: allowGuestAuthentication
        )

        var fullBody = body
        fullBody["context"] = self.buildContext(authenticated: requestAuth.authenticated)

        let cacheScope = self.cacheScope(authenticated: requestAuth.authenticated)
        let cacheKey = APICache.stableCacheKey(endpoint: endpoint, body: fullBody, brandId: cacheScope)
        if let cacheKey {
            self.logger.debug("Request \(endpoint): cacheKey=\(cacheKey)")
        } else {
            self.logger.debug("Request \(endpoint): skipping cache due to unstable cache key")
        }

        if ttl != nil, !bypassCache, let cacheKey, let cached = self.cache.get(key: cacheKey) {
            self.logger.debug("Cache hit for \(endpoint)")
            return cached
        }

        let cacheWrite: APICache.WriteReservation? = if let cacheKey, let cacheWriteTicket {
            self.cache.beginWrite(for: cacheKey, ticket: cacheWriteTicket)
        } else {
            nil
        }

        let json = try await RetryPolicy.default.execute { [self] in
            try await self.performRequest(
                endpoint,
                fullBody: fullBody,
                requestAuth: requestAuth
            )
        }

        if let ttl, let cacheKey, let cacheWrite {
            self.cache.setIfCurrent(
                key: cacheKey,
                data: json,
                ttl: ttl,
                reservation: cacheWrite
            )
        }

        return json
    }

    private func performRequest(
        _ endpoint: String,
        fullBody: [String: Any],
        requestAuth: RequestAuthHeaders
    ) async throws -> [String: Any] {
        let authenticated = requestAuth.authenticated
        let authIdentityGeneration = requestAuth.authIdentityGeneration
        let allowGuestAuthentication = requestAuth.allowsGuestAuthentication
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration,
            allowGuestAuthentication: allowGuestAuthentication
        )
        let apiKey = try await self.resolveAPIKey()
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration,
            allowGuestAuthentication: allowGuestAuthentication
        )
        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YTMusicError.unknown(message: "Invalid API URL for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = authenticated

        for (key, value) in requestAuth.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        if let context = fullBody["context"] as? [String: Any],
           let user = context["user"] as? [String: Any]
        {
            let onBehalfOfUser = user["onBehalfOfUser"] as? String
            self.logger.debug(
                "Making request to \(endpoint) (onBehalfOfUser=\(onBehalfOfUser ?? "primary"))"
            )
        } else {
            self.logger.debug("Making request to \(endpoint) (missing context)")
        }

        let result = try await Self.performNetworkRequest(request: request, session: self.session)
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration,
            allowGuestAuthentication: allowGuestAuthentication
        )

        switch result {
        case let .success(data):
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YTMusicError.parseError(message: "Response is not a JSON object")
            }
            return json
        case let .authError(statusCode):
            self.logger.error("Auth error: HTTP \(statusCode)")
            if authenticated {
                if let authIdentityGeneration {
                    self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                }
                throw YTMusicError.authExpired
            }
            throw YTMusicError.notAuthenticated
        case let .httpError(statusCode):
            self.logger.error("API error: HTTP \(statusCode)")
            throw YTMusicError.apiError(
                message: "HTTP \(statusCode)",
                code: statusCode
            )
        case let .networkError(error):
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw YTMusicError.networkError(underlying: error)
        }
    }

    private func canUseAuthenticatedSession(allowGuestAuthentication: Bool) -> Bool {
        self.authService.hasPersonalAccount
            || (allowGuestAuthentication
                && self.authService.state.isLoggedIn
                && self.authService.isGuestModeEnabled)
    }

    private func validateAuthIdentity(
        authenticated: Bool,
        generation: UInt64?,
        allowGuestAuthentication: Bool
    ) throws {
        guard authenticated else { return }
        guard let generation,
              generation == self.authService.accountIdentityGeneration,
              self.canUseAuthenticatedSession(allowGuestAuthentication: allowGuestAuthentication)
        else {
            throw CancellationError()
        }
    }

    private func resolveAPIKey() async throws -> String {
        try await self.apiKeyResolver.resolve()
    }

    private enum NetworkResult {
        case success(Data)
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }

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

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .authError(statusCode: httpResponse.statusCode)
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                return .httpError(statusCode: httpResponse.statusCode)
            }

            return .success(data)
        } catch {
            return .networkError(error)
        }
    }
}

@MainActor
final class YTMusicAPIKeyResolver {
    nonisolated static let environmentVariable = "KASET_YTMUSIC_API_KEY"
    nonisolated static let defaultWebClientURL = URL(string: "https://music.youtube.com")!

    private let session: URLSession
    private let environment: @Sendable (String) -> String?
    private let webClientURL: URL
    private var cachedAPIKey: String?
    private var inFlightResolve: Task<String, any Error>?

    init(
        session: URLSession = .shared,
        webClientURL: URL = defaultWebClientURL,
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) {
        self.session = session
        self.webClientURL = webClientURL
        self.environment = environment
    }

    func resolve() async throws -> String {
        if let cachedAPIKey {
            return cachedAPIKey
        }

        if let override = self.environment(Self.environmentVariable),
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            self.cachedAPIKey = trimmed
            return trimmed
        }

        if let inFlightResolve {
            return try await inFlightResolve.value
        }

        let task = Task { [session, webClientURL] in
            try await Self.fetchAPIKey(session: session, webClientURL: webClientURL)
        }
        self.inFlightResolve = task

        do {
            let apiKey = try await task.value
            self.cachedAPIKey = apiKey
            self.inFlightResolve = nil
            return apiKey
        } catch {
            self.inFlightResolve = nil
            throw error
        }
    }

    private static func fetchAPIKey(session: URLSession, webClientURL: URL) async throws -> String {
        do {
            var request = URLRequest(url: webClientURL)
            request.setValue(APISessionConfiguration.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpShouldHandleCookies = false
            request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200 ... 399).contains(httpResponse.statusCode)
            {
                throw YTMusicError.apiError(
                    message: "Could not load YouTube Music web client configuration",
                    code: httpResponse.statusCode
                )
            }

            guard let html = String(data: data, encoding: .utf8),
                  let apiKey = Self.extractInnertubeAPIKey(from: html)
            else {
                throw YTMusicError.parseError(message: "Could not resolve YouTube Music API configuration")
            }

            return apiKey
        } catch let error as YTMusicError {
            throw error
        } catch {
            throw YTMusicError.networkError(underlying: error)
        }
    }

    static func extractInnertubeAPIKey(from html: String) -> String? {
        let pattern = #""INNERTUBE_API_KEY"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: html,
                  range: NSRange(html.startIndex ..< html.endIndex, in: html)
              ),
              let range = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        return String(html[range])
    }
}
