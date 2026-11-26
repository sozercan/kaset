import Foundation
import Observation
import os

@MainActor
@Observable
final class SearchViewModel {
    private(set) var loadingState: LoadingState = .idle

    var query: String = "" {
        didSet {
            if oldValue != self.query {
                self.resultGeneration &+= 1
            }
            self.searchTask?.cancel()
            self.suggestionsTask?.cancel()
            self.allSearchEnrichmentID = nil
            if self.query != self.suppressedSuggestionsQuery {
                self.suppressedSuggestionsQuery = nil
            }
            if self.query.isEmpty {
                self.results = .empty
                self.suggestions = []
                self.loadingState = .idle
                self.lastSearchedQuery = nil
                self.suppressedSuggestionsQuery = nil
            } else if self.query != self.lastSearchedQuery {
                self.results = .empty
                self.loadingState = .idle
            }
        }
    }

    private(set) var results: SearchResponse = .empty

    private var lastSearchedQuery: String?

    private var lastSearchedFilter: SearchFilter?

    private(set) var suggestions: [SearchSuggestion] = []

    var shouldShowFilters: Bool {
        guard !self.query.isEmpty,
              self.lastSearchedQuery == self.query,
              self.allSearchEnrichmentID == nil
        else {
            return false
        }

        switch self.loadingState {
        case .loading, .loaded, .loadingMore:
            return true
        case .idle, .error:
            return false
        }
    }

    var showSuggestions: Bool {
        !self.query.isEmpty &&
            self.query != self.suppressedSuggestionsQuery &&
            !self.suggestions.isEmpty &&
            self.results.isEmpty &&
            self.loadingState == .idle
    }

    var selectedFilter: SearchFilter = .all {
        didSet {
            guard oldValue != self.selectedFilter, !self.query.isEmpty else { return }

            if self.lastSearchedQuery != nil {
                self.searchWithFilter()
            } else {
                self.searchImmediately()
            }
        }
    }

    var hasMoreResults: Bool {
        guard self.selectedFilter != .all else { return false }
        return self.results.hasMore
    }

    enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case songs = "Songs"
        case videos = "Videos"
        case albums = "Albums"
        case artists = "Artists"
        case profiles = "Profiles"
        case featuredPlaylists = "Featured playlists"
        case communityPlaylists = "Community playlists"
        case podcasts = "Podcasts"
        case episodes = "Episodes"

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .all:
                String(localized: "All")
            case .songs:
                String(localized: "Songs")
            case .videos:
                String(localized: "Videos")
            case .albums:
                String(localized: "Albums")
            case .artists:
                String(localized: "Artists")
            case .profiles:
                String(localized: "Profiles")
            case .featuredPlaylists:
                String(localized: "Featured playlists")
            case .communityPlaylists:
                String(localized: "Community playlists")
            case .podcasts:
                String(localized: "Podcasts")
            case .episodes:
                String(localized: "Episodes")
            }
        }
    }

    var filteredItems: [SearchResultItem] {
        switch self.selectedFilter {
        case .all:
            self.results.allItems
        case .songs:
            self.results.songs.map { .song($0) }
        case .videos:
            self.results.videos.map { .video($0) }
        case .albums:
            self.results.allItems.filter { item in
                switch item {
                case .album, .audiobook:
                    true
                default:
                    false
                }
            }
        case .artists:
            self.results.artists.map { .artist($0) }
        case .profiles:
            self.results.profiles.map { .profile($0) }
        case .featuredPlaylists, .communityPlaylists:
            self.results.playlists.map { .playlist($0) }
        case .podcasts:
            self.results.podcastShows.map { .podcastShow($0) }
        case .episodes:
            self.results.podcastEpisodes.map { .podcastEpisode($0) }
        }
    }

    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api
    // swiftformat:disable modifierOrder
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionsTask: Task<Void, Never>?
    @ObservationIgnored private var resultGeneration: UInt = 0
    @ObservationIgnored private var suppressedSuggestionsQuery: String?
    // swiftformat:enable modifierOrder

    private struct SearchAllAttempt {
        let response: SearchResponse?
        let error: (any Error)?
    }

    private var allSearchEnrichmentID: UUID?

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    deinit {
        searchTask?.cancel()
        suggestionsTask?.cancel()
    }

    func fetchSuggestions() {
        self.suggestionsTask?.cancel()

        guard !self.query.isEmpty, self.query != self.suppressedSuggestionsQuery else {
            self.suggestions = []
            return
        }

        self.suggestionsTask = Task {
            try? await Task.sleep(for: .milliseconds(150))

            guard !Task.isCancelled else { return }

            await self.performFetchSuggestions()
        }
    }

    private func performFetchSuggestions() async {
        let currentQuery = self.query

        do {
            let fetchedSuggestions = try await client.getSearchSuggestions(query: currentQuery)
            if self.query == currentQuery, currentQuery != self.suppressedSuggestionsQuery {
                self.suggestions = fetchedSuggestions
            }
        } catch {
            if !Task.isCancelled {
                self.logger.debug("Failed to fetch suggestions: \(error.localizedDescription)")
            }
        }
    }

    func selectSuggestion(_ suggestion: SearchSuggestion) {
        self.suggestionsTask?.cancel()
        self.suggestions = []
        self.suppressedSuggestionsQuery = suggestion.query
        self.query = suggestion.query
        self.search()
    }

    func clearSuggestions() {
        self.suggestionsTask?.cancel()
        self.suggestions = []
    }

    func search() {
        self.resultGeneration &+= 1
        self.searchTask?.cancel()
        self.suggestionsTask?.cancel()
        self.allSearchEnrichmentID = nil
        self.suggestions = []
        self.suppressedSuggestionsQuery = self.query

        guard !self.query.isEmpty else {
            self.results = .empty
            self.loadingState = .idle
            return
        }

        self.searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            await self.performSearch()
        }
    }

    func searchImmediately() {
        self.resultGeneration &+= 1
        self.searchTask?.cancel()
        self.suggestionsTask?.cancel()
        self.allSearchEnrichmentID = nil
        self.suggestions = []
        self.suppressedSuggestionsQuery = self.query

        guard !self.query.isEmpty else {
            self.results = .empty
            self.loadingState = .idle
            return
        }

        self.searchTask = Task {
            await self.performSearch()
        }
    }

    private func searchWithFilter() {
        self.resultGeneration &+= 1
        self.searchTask?.cancel()
        self.allSearchEnrichmentID = nil

        guard !self.query.isEmpty else {
            self.results = .empty
            self.loadingState = .idle
            return
        }

        self.searchTask = Task {
            await self.performSearch()
        }
    }

    private func performSearch() async {
        guard !Task.isCancelled else { return }

        self.loadingState = .loading
        let currentQuery = self.query
        let currentFilter = self.selectedFilter
        let allSearchEnrichmentID = currentFilter == .all ? UUID() : nil
        if let allSearchEnrichmentID {
            self.allSearchEnrichmentID = allSearchEnrichmentID
        }
        defer {
            if let allSearchEnrichmentID, self.allSearchEnrichmentID == allSearchEnrichmentID {
                self.allSearchEnrichmentID = nil
            }
        }
        self.logger.info("Searching for: \(currentQuery) with filter: \(currentFilter.rawValue)")

        do {
            let searchResults = try await self.executeSearch(
                query: currentQuery,
                filter: currentFilter
            )

            guard self.isCurrentSearch(query: currentQuery, filter: currentFilter) else {
                self.logger.debug("Search results discarded: query/filter changed or task cancelled")
                return
            }

            self.publishSearchResults(searchResults, query: currentQuery, filter: currentFilter)
            self.logger.info("Search complete: \(searchResults.allItems.count) results, hasMore: \(searchResults.hasMore)")
        } catch {
            if self.isCurrentSearch(query: currentQuery, filter: currentFilter) {
                self.logger.error("Search failed: \(error.localizedDescription)")
                self.loadingState = .error(LoadingError(from: error))
            }
        }
    }

    private func executeSearch(query: String, filter: SearchFilter) async throws -> SearchResponse {
        switch filter {
        case .all:
            try await self.searchAll(query: query, filter: filter)
        case .songs:
            try await self.client.searchSongsWithPagination(query: query)
        case .videos:
            try await self.client.searchVideos(query: query)
        case .albums:
            try await self.client.searchAlbums(query: query)
        case .artists:
            try await self.client.searchArtists(query: query)
        case .profiles:
            try await self.client.searchProfiles(query: query)
        case .featuredPlaylists:
            try await self.client.searchFeaturedPlaylists(query: query)
        case .communityPlaylists:
            try await self.client.searchCommunityPlaylists(query: query)
        case .podcasts:
            try await self.client.searchPodcasts(query: query)
        case .episodes:
            try await self.client.searchEpisodes(query: query)
        }
    }

    private func isCurrentSearch(query: String, filter: SearchFilter) -> Bool {
        !Task.isCancelled && self.query == query && self.selectedFilter == filter
    }

    private func publishSearchResults(_ results: SearchResponse, query: String, filter: SearchFilter) {
        self.results = results
        self.lastSearchedQuery = query
        self.lastSearchedFilter = filter
        self.loadingState = .loaded
    }

    private func searchAll(query: String, filter: SearchFilter) async throws -> SearchResponse {
        let mixedAttempt = await self.attemptSearch(label: "mixed search") {
            try await self.client.search(query: query)
        }

        if let authError = mixedAttempt.error.flatMap(Self.authenticationError) {
            throw authError
        }

        if let mixedResponse = mixedAttempt.response, !mixedResponse.isEmpty {
            return mixedResponse
        }

        guard self.isCurrentSearch(query: query, filter: filter) else {
            throw CancellationError()
        }

        return try await self.searchAllCategoryFallback(
            query: query,
            mixedError: mixedAttempt.error
        )
    }

    private func searchAllCategoryFallback(query: String, mixedError: (any Error)?) async throws -> SearchResponse {
        async let songResults = self.attemptSearch(label: "songs search") {
            try await self.client.searchSongsWithPagination(query: query)
        }
        async let videoResults = self.attemptSearch(label: "videos search") {
            try await self.client.searchVideos(query: query)
        }
        async let albumResults = self.attemptSearch(label: "albums search") {
            try await self.client.searchAlbums(query: query)
        }
        async let artistResults = self.attemptSearch(label: "artists search") {
            try await self.client.searchArtists(query: query)
        }
        async let profileResults = self.attemptSearch(label: "profiles search") {
            try await self.client.searchProfiles(query: query)
        }
        async let featuredPlaylistResults = self.attemptSearch(label: "featured playlists search") {
            try await self.client.searchFeaturedPlaylists(query: query)
        }
        async let communityPlaylistResults = self.attemptSearch(label: "community playlists search") {
            try await self.client.searchCommunityPlaylists(query: query)
        }
        async let podcastResults = self.attemptSearch(label: "podcasts search") {
            try await self.client.searchPodcasts(query: query)
        }
        async let episodeResults = self.attemptSearch(label: "episodes search") {
            try await self.client.searchEpisodes(query: query)
        }

        let attempts = await [
            songResults,
            videoResults,
            albumResults,
            artistResults,
            profileResults,
            featuredPlaylistResults,
            communityPlaylistResults,
            podcastResults,
            episodeResults,
        ]

        if let authError = attempts.compactMap(\.error).compactMap(Self.authenticationError).first {
            throw authError
        }

        let responses = attempts.compactMap(\.response)
        guard !responses.isEmpty else {
            throw attempts.compactMap(\.error).first ?? mixedError ?? YTMusicError.unknown(message: "All-filter search failed")
        }

        return Self.mergeSearchResponses(responses)
    }

    private func attemptSearch(
        label: String,
        operation: @escaping @Sendable () async throws -> SearchResponse
    ) async -> SearchAllAttempt {
        do {
            let response = try await operation()
            return SearchAllAttempt(response: response, error: nil)
        } catch {
            self.logger.debug("All-filter \(label) failed: \(error.localizedDescription)")
            return SearchAllAttempt(response: nil, error: error)
        }
    }

    private static func isAuthenticationError(_ error: any Error) -> Bool {
        self.authenticationError(error) != nil
    }

    private static func authenticationError(_ error: (any Error)?) -> YTMusicError? {
        guard let ytError = error as? YTMusicError, ytError.requiresReauth else { return nil }
        return ytError
    }

    private static func mergeSearchResponses(_ responses: [SearchResponse]) -> SearchResponse {
        var items: [SearchResultItem] = []
        var seenContent: Set<String> = []

        for response in responses {
            for item in response.allItems where seenContent.insert(item.contentIdentity).inserted {
                items.append(item)
            }
        }

        return SearchResponse(items: items, continuationToken: nil)
    }

    func loadMore() async {
        guard self.selectedFilter != .all else { return }
        guard self.loadingState == .loaded else { return }
        guard self.hasMoreResults else { return }
        guard let continuationToken = self.results.continuationToken else { return }

        let generation = self.resultGeneration
        let currentQuery = self.query
        let currentFilter = self.selectedFilter
        let baseResults = self.results

        self.loadingState = .loadingMore
        self.logger.info("Loading more search results")

        do {
            let continuation = try await self.client.getSearchContinuation(token: continuationToken)

            guard self.isCurrentPagination(
                query: currentQuery,
                filter: currentFilter,
                token: continuationToken,
                generation: generation
            ) else {
                self.logger.debug("Search continuation discarded: query/filter/results changed")
                return
            }

            let mergedResults = Self.mergeSearchResponses([baseResults, continuation])
            let paginatedResults = SearchResponse(
                items: mergedResults.allItems,
                continuationToken: continuation.continuationToken
            )

            self.results = paginatedResults
            self.loadingState = .loaded
            self.logger.info("Loaded more results: now \(paginatedResults.allItems.count) total, hasMore: \(paginatedResults.hasMore)")
        } catch {
            guard self.isCurrentPagination(
                query: currentQuery,
                filter: currentFilter,
                token: continuationToken,
                generation: generation
            ) else {
                return
            }
            self.logger.error("Failed to load more: \(error.localizedDescription)")
            self.loadingState = .loaded
        }
    }

    private func isCurrentPagination(
        query: String,
        filter: SearchFilter,
        token: String,
        generation: UInt
    ) -> Bool {
        !Task.isCancelled
            && self.resultGeneration == generation
            && self.query == query
            && self.selectedFilter == filter
            && self.results.continuationToken == token
            && self.loadingState == .loadingMore
    }

    func clear() {
        self.resultGeneration &+= 1
        self.searchTask?.cancel()
        self.suggestionsTask?.cancel()
        self.query = ""
        self.results = .empty
        self.suggestions = []
        self.lastSearchedQuery = nil
        self.lastSearchedFilter = nil
        self.suppressedSuggestionsQuery = nil
        self.allSearchEnrichmentID = nil
        self.loadingState = .idle
    }
}
