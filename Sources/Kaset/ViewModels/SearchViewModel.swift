import Foundation
import Observation
import os

/// View model for the Search view.
@MainActor
@Observable
final class SearchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Current search query.
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
                // Clear results when query changes from what was searched
                self.results = .empty
                self.loadingState = .idle
            }
        }
    }

    /// Search results.
    private(set) var results: SearchResponse = .empty

    /// The query that produced the current results.
    private var lastSearchedQuery: String?

    /// The filter that produced the current results.
    private var lastSearchedFilter: SearchFilter?

    /// Search suggestions for autocomplete.
    private(set) var suggestions: [SearchSuggestion] = []

    /// Whether filters should be shown for the current search.
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

    /// Whether suggestions should be shown.
    var showSuggestions: Bool {
        !self.query.isEmpty &&
            self.query != self.suppressedSuggestionsQuery &&
            !self.suggestions.isEmpty &&
            self.results.isEmpty &&
            self.loadingState == .idle
    }

    /// Filter for result types.
    var selectedFilter: SearchFilter = .all {
        didSet {
            guard oldValue != self.selectedFilter, !self.query.isEmpty else { return }

            // If we've previously searched this query, perform a filtered search
            // to get the best results for the selected filter. If no prior
            // search exists (e.g. user typed a query but hasn't pressed Enter),
            // perform an immediate search for the current filter so clicking
            // filter chips always produces results.
            if self.lastSearchedQuery != nil {
                self.searchWithFilter()
            } else {
                self.searchImmediately()
            }
        }
    }

    /// Whether more results are available to load.
    var hasMoreResults: Bool {
        // For "All" filter, we don't support pagination (mixed results)
        guard self.selectedFilter != .all else { return false }
        return self.results.hasMore
    }

    /// Available filters.
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

    /// Filtered results based on selected filter.
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
    /// Tasks for search operations, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access; Swift 6.2 warning is expected.
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionsTask: Task<Void, Never>?
    @ObservationIgnored private var resultGeneration: UInt = 0
    @ObservationIgnored private var suppressedSuggestionsQuery: String?
    // swiftformat:enable modifierOrder

    private struct SearchAllAttempt {
        let response: SearchResponse?
        let error: (any Error)?
    }

    /// Non-nil while an All-filter search has published its mixed first paint
    /// but is still awaiting dedicated category requests.
    private var allSearchEnrichmentID: UUID?

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    deinit {
        searchTask?.cancel()
        suggestionsTask?.cancel()
    }

    /// Fetches search suggestions with debounce.
    func fetchSuggestions() {
        self.suggestionsTask?.cancel()

        guard !self.query.isEmpty, self.query != self.suppressedSuggestionsQuery else {
            self.suggestions = []
            return
        }

        self.suggestionsTask = Task {
            // Faster debounce for suggestions (150ms vs 300ms for search)
            try? await Task.sleep(for: .milliseconds(150))

            guard !Task.isCancelled else { return }

            await self.performFetchSuggestions()
        }
    }

    /// Performs the actual suggestions fetch.
    private func performFetchSuggestions() async {
        let currentQuery = self.query

        do {
            let fetchedSuggestions = try await client.getSearchSuggestions(query: currentQuery)
            // Only update if query hasn't changed and this query was not explicitly submitted.
            if self.query == currentQuery, currentQuery != self.suppressedSuggestionsQuery {
                self.suggestions = fetchedSuggestions
            }
        } catch {
            if !Task.isCancelled {
                self.logger.debug("Failed to fetch suggestions: \(error.localizedDescription)")
                // Don't show error for suggestions - just silently fail
            }
        }
    }

    /// Selects a suggestion and triggers search.
    func selectSuggestion(_ suggestion: SearchSuggestion) {
        self.suggestionsTask?.cancel()
        self.suggestions = []
        self.suppressedSuggestionsQuery = suggestion.query
        self.query = suggestion.query
        self.search()
    }

    /// Clears suggestions without affecting search.
    func clearSuggestions() {
        self.suggestionsTask?.cancel()
        self.suggestions = []
    }

    /// Performs a search with debounce.
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
            // Debounce: wait a bit before searching
            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            await self.performSearch()
        }
    }

    /// Performs a search immediately without debounce.
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

    /// Performs a search with the current filter (no debounce, called when filter changes).
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

    /// Performs the actual search.
    private func performSearch() async {
        // Check cancellation before updating state
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

            // Check cancellation and query change before updating results
            // This handles the race condition where query changed during the request
            guard self.isCurrentSearch(query: currentQuery, filter: currentFilter) else {
                self.logger.debug("Search results discarded: query/filter changed or task cancelled")
                return
            }

            self.publishSearchResults(searchResults, query: currentQuery, filter: currentFilter)
            self.logger.info("Search complete: \(searchResults.allItems.count) results, hasMore: \(searchResults.hasMore)")
        } catch {
            // CancellationError is thrown when task is cancelled during URLSession request
            if self.isCurrentSearch(query: currentQuery, filter: currentFilter) {
                self.logger.error("Search failed: \(error.localizedDescription)")
                self.loadingState = .error(LoadingError(from: error))
            }
        }
    }

    /// Routes one query to the endpoint owned by the selected filter.
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

    /// Performs the All-filter search. The mixed search response usually already contains
    /// representative results for every visible category, so keep the common path to a single
    /// request. Dedicated category searches are only used as a fallback when mixed search returns
    /// nothing (or fails with a non-auth transient error), avoiding seven-request fanout per query.
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

    /// Runs dedicated category searches only when the mixed All response cannot paint useful
    /// results. This preserves empty-mixed fallback quality without paying the network/WebKit
    /// authentication cost on every ordinary All search.
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

    /// Runs one All-filter search request, preserving failures so total failure still surfaces as an error.
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

    /// Combines multiple search responses while keeping the first occurrence of each item.
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

    /// Loads more search results via continuation.
    func loadMore() async {
        // Only load more for filtered searches
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
            self.loadingState = .loaded // Revert to loaded state to allow retry
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

    /// Clears search results.
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
