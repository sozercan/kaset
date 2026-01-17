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
            self.searchTask?.cancel()
            self.suggestionsTask?.cancel()
            if self.query.isEmpty {
                self.results = .empty
                self.suggestions = []
                self.loadingState = .idle
                self.lastSearchedQuery = nil
                self.client.clearSearchContinuation()
            } else if self.query != self.lastSearchedQuery {
                // Clear results when query changes from what was searched
                self.results = .empty
                self.loadingState = .idle
                self.client.clearSearchContinuation()
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

    /// Whether suggestions should be shown.
    var showSuggestions: Bool {
        !self.query.isEmpty && !self.suggestions.isEmpty && self.results.isEmpty
    }

    /// Filter for result types.
    var selectedFilter: SearchFilter = .all {
        didSet {
            if oldValue != self.selectedFilter, !self.query.isEmpty, self.lastSearchedQuery != nil {
                // Filter changed - perform a new filtered search
                self.searchWithFilter()
            }
        }
    }

    /// Whether more results are available to load.
    var hasMoreResults: Bool {
        // For "All" filter, we don't support pagination (mixed results)
        guard self.selectedFilter != .all else { return false }
        return self.client.hasMoreSearchResults
    }

    /// Available filters.
    enum SearchFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        case featuredPlaylists = "Featured playlists"
        case communityPlaylists = "Community playlists"
        case podcasts = "Podcasts"

        var id: String { rawValue }
    }

    /// Filtered results based on selected filter.
    var filteredItems: [SearchResultItem] {
        switch self.selectedFilter {
        case .all:
            self.results.allItems
        case .songs:
            self.results.songs.map { .song($0) }
        case .albums:
            self.results.albums.map { .album($0) }
        case .artists:
            self.results.artists.map { .artist($0) }
        case .featuredPlaylists, .communityPlaylists:
            self.results.playlists.map { .playlist($0) }
        case .podcasts:
            self.results.podcastShows.map { .podcastShow($0) }
        }
    }

    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api
    // swiftformat:disable modifierOrder
    /// Tasks for search operations, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access; Swift 6.2 warning is expected.
    nonisolated(unsafe) private var searchTask: Task<Void, Never>?
    nonisolated(unsafe) private var suggestionsTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

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

        guard !self.query.isEmpty else {
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
            // Only update if query hasn't changed
            if self.query == currentQuery {
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
        self.searchTask?.cancel()
        self.suggestionsTask?.cancel()
        self.suggestions = []
        self.client.clearSearchContinuation()

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

    /// Performs a search with the current filter (no debounce, called when filter changes).
    private func searchWithFilter() {
        self.searchTask?.cancel()
        self.client.clearSearchContinuation()

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
        self.logger.info("Searching for: \(currentQuery) with filter: \(currentFilter.rawValue)")

        do {
            let searchResults: SearchResponse

                // Use filtered search for specific filters to get more results
                = switch currentFilter
            {
            case .all:
                try await self.client.search(query: currentQuery)
            case .songs:
                try await self.client.searchSongsWithPagination(query: currentQuery)
            case .albums:
                try await self.client.searchAlbums(query: currentQuery)
            case .artists:
                try await self.client.searchArtists(query: currentQuery)
            case .featuredPlaylists:
                try await self.client.searchFeaturedPlaylists(query: currentQuery)
            case .communityPlaylists:
                try await self.client.searchCommunityPlaylists(query: currentQuery)
            case .podcasts:
                try await self.client.searchPodcasts(query: currentQuery)
            }

            // Check cancellation and query change before updating results
            // This handles the race condition where query changed during the request
            guard !Task.isCancelled, self.query == currentQuery else {
                self.logger.debug("Search results discarded: query changed or task cancelled")
                return
            }

            self.results = searchResults
            self.lastSearchedQuery = currentQuery
            self.lastSearchedFilter = currentFilter
            self.loadingState = .loaded
            self.logger.info("Search complete: \(searchResults.allItems.count) results, hasMore: \(searchResults.hasMore)")
        } catch {
            // CancellationError is thrown when task is cancelled during URLSession request
            if !Task.isCancelled, self.query == currentQuery {
                self.logger.error("Search failed: \(error.localizedDescription)")
                self.loadingState = .error(LoadingError(from: error))
            }
        }
    }

    /// Loads more search results via continuation.
    func loadMore() async {
        // Only load more for filtered searches
        guard self.selectedFilter != .all else { return }
        guard self.loadingState == .loaded else { return }
        guard self.hasMoreResults else { return }

        self.loadingState = .loadingMore
        self.logger.info("Loading more search results")

        do {
            guard let continuation = try await client.getSearchContinuation() else {
                self.loadingState = .loaded
                return
            }

            // Merge continuation results with existing results
            let mergedResults = SearchResponse(
                songs: self.results.songs + continuation.songs,
                albums: self.results.albums + continuation.albums,
                artists: self.results.artists + continuation.artists,
                playlists: self.results.playlists + continuation.playlists,
                podcastShows: self.results.podcastShows + continuation.podcastShows,
                continuationToken: continuation.continuationToken
            )

            self.results = mergedResults
            self.loadingState = .loaded
            self.logger.info("Loaded more results: now \(mergedResults.allItems.count) total, hasMore: \(mergedResults.hasMore)")
        } catch {
            self.logger.error("Failed to load more: \(error.localizedDescription)")
            self.loadingState = .loaded // Revert to loaded state to allow retry
        }
    }

    /// Clears search results.
    func clear() {
        self.searchTask?.cancel()
        self.suggestionsTask?.cancel()
        self.query = ""
        self.results = .empty
        self.suggestions = []
        self.lastSearchedQuery = nil
        self.lastSearchedFilter = nil
        self.loadingState = .idle
        self.client.clearSearchContinuation()
    }
}
