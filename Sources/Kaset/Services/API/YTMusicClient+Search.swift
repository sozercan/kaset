import Foundation

private enum SearchFilterParams {
    static let songs = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    static let albums = "EgWKAQIYAWoMEA4QChADEAQQCRAF"
    static let artists = "EgWKAQIgAWoMEA4QChADEAQQCRAF"
    static let playlists = "EgWKAQIoAWoMEA4QChADEAQQCRAF"
    static let featuredPlaylists = "EgeKAQQoADgBagwQDhAKEAMQBBAJEAU="
    static let communityPlaylists = "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU="
    static let podcasts = "EgWKAQJQAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D"
}

// MARK: - Search APIs

@MainActor
extension YTMusicClient {
    func search(query: String) async throws -> SearchResponse {
        self.logger.info("Searching for: \(query)")

        let body: [String: Any] = [
            "query": query,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Search found \(response.songs.count) songs, \(response.albums.count) albums, \(response.artists.count) artists, \(response.playlists.count) playlists")
        return response
    }

    func searchSongs(query: String) async throws -> [Song] {
        self.logger.info("Searching songs only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.songs,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        let songs = SearchResponseParser.parseSongsOnly(data)
        self.logger.info("Songs search found \(songs.count) songs")
        return songs
    }

    var hasMoreSearchResults: Bool {
        self.searchContinuationToken != nil
    }

    func searchAlbums(query: String) async throws -> SearchResponse {
        self.logger.info("Searching albums only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.albums,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        let (albums, token) = SearchResponseParser.parseAlbumsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Albums search found \(albums.count) albums, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: albums, artists: [], playlists: [], continuationToken: token)
    }

    func searchArtists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching artists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.artists,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        let (artists, token) = SearchResponseParser.parseArtistsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Artists search found \(artists.count) artists, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: [], artists: artists, playlists: [], continuationToken: token)
    }

    func searchPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.playlists,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        let (playlists, token) = SearchResponseParser.parsePlaylistsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Playlists search found \(playlists.count) playlists, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: [], artists: [], playlists: playlists, continuationToken: token)
    }

    func searchFeaturedPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching featured playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.featuredPlaylists,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        let (playlists, token) = SearchResponseParser.parsePlaylistsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Featured playlists search found \(playlists.count) playlists, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: [], artists: [], playlists: playlists, continuationToken: token)
    }

    func searchCommunityPlaylists(query: String) async throws -> SearchResponse {
        self.logger.info("Searching community playlists only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.communityPlaylists,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        let (playlists, token) = SearchResponseParser.parsePlaylistsOnly(data)
        self.searchContinuationToken = token

        self.logger.info("Community playlists search found \(playlists.count) playlists, hasMore: \(token != nil)")
        return SearchResponse(songs: [], albums: [], artists: [], playlists: playlists, continuationToken: token)
    }

    func searchPodcasts(query: String) async throws -> SearchResponse {
        self.logger.info("Searching podcasts only for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.podcasts,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
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

    func searchSongsWithPagination(query: String) async throws -> SearchResponse {
        self.logger.info("Searching songs with pagination for: \(query)")

        let body: [String: Any] = [
            "query": query,
            "params": SearchFilterParams.songs,
        ]

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        let (songs, token) = SearchResponseParser.parseSongsWithContinuation(data)
        self.searchContinuationToken = token

        self.logger.info("Songs search found \(songs.count) songs, hasMore: \(token != nil)")
        return SearchResponse(songs: songs, albums: [], artists: [], playlists: [], continuationToken: token)
    }

    func getSearchContinuation() async throws -> SearchResponse? {
        guard let token = self.searchContinuationToken else {
            self.logger.debug("No search continuation token available")
            return nil
        }

        self.logger.info("Fetching search continuation")

        do {
            let continuationData = try await self.requestContinuation(token, ttl: APICache.TTL.search)
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

    func clearSearchContinuation() {
        self.searchContinuationToken = nil
    }

    func resetSessionStateForAccountSwitch() {
        self.logger.info("Resetting client session state for account switch")
        self.continuationTokens.removeAll()
        self.searchContinuationToken = nil
        self.likedSongsContinuationToken = nil
        self.playlistContinuationToken = nil
    }

    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion] {
        guard !query.isEmpty else {
            return []
        }

        self.logger.debug("Fetching search suggestions for: \(query)")

        let body: [String: Any] = [
            "input": query,
        ]

        let data = try await self.request("music/get_search_suggestions", body: body)
        let suggestions = SearchSuggestionsParser.parse(data)
        self.logger.debug("Found \(suggestions.count) suggestions")
        return suggestions
    }
}
