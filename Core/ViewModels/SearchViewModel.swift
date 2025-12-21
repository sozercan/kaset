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

    /// Search suggestions for autocomplete.
    private(set) var suggestions: [SearchSuggestion] = []

    /// Whether suggestions should be shown.
    var showSuggestions: Bool {
        !self.query.isEmpty && !self.suggestions.isEmpty && self.results.isEmpty
    }

    /// Filter for result types.
    var selectedFilter: SearchFilter = .all

    /// Available filters.
    enum SearchFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        case playlists = "Playlists"

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
        case .playlists:
            self.results.playlists.map { .playlist($0) }
        }
    }

    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api
    private var searchTask: Task<Void, Never>?
    private var suggestionsTask: Task<Void, Never>?

    init(client: any YTMusicClientProtocol) {
        self.client = client
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

    /// Performs the actual search.
    private func performSearch() async {
        self.loadingState = .loading
        let currentQuery = self.query
        self.logger.info("Searching for: \(currentQuery)")

        do {
            let searchResults = try await client.search(query: currentQuery)
            self.results = searchResults
            self.lastSearchedQuery = currentQuery
            self.loadingState = .loaded
            self.logger.info("Search complete: \(searchResults.allItems.count) results")
        } catch {
            if !Task.isCancelled {
                self.logger.error("Search failed: \(error.localizedDescription)")
                self.loadingState = .error(error.localizedDescription)
            }
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
        self.loadingState = .idle
    }
}
