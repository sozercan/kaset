import Foundation
import Observation
import os

/// View model for the Search view.
@MainActor
@Observable
final class SearchViewModel {
    /// Loading states for the view.
    enum LoadingState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Current search query.
    var query: String = "" {
        didSet {
            searchTask?.cancel()
            if query.isEmpty {
                results = .empty
                loadingState = .idle
            }
        }
    }

    /// Search results.
    private(set) var results: SearchResponse = .empty

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
        switch selectedFilter {
        case .all:
            results.allItems
        case .songs:
            results.songs.map { .song($0) }
        case .albums:
            results.albums.map { .album($0) }
        case .artists:
            results.artists.map { .artist($0) }
        case .playlists:
            results.playlists.map { .playlist($0) }
        }
    }

    private let client: YTMusicClient
    private let logger = DiagnosticsLogger.api
    private var searchTask: Task<Void, Never>?

    init(client: YTMusicClient) {
        self.client = client
    }

    /// Performs a search with debounce.
    func search() {
        searchTask?.cancel()

        guard !query.isEmpty else {
            results = .empty
            loadingState = .idle
            return
        }

        searchTask = Task {
            // Debounce: wait a bit before searching
            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            await performSearch()
        }
    }

    /// Performs the actual search.
    private func performSearch() async {
        loadingState = .loading
        let currentQuery = query
        logger.info("Searching for: \(currentQuery)")

        do {
            let searchResults = try await client.search(query: currentQuery)
            results = searchResults
            loadingState = .loaded
            logger.info("Search complete: \(searchResults.allItems.count) results")
        } catch {
            if !Task.isCancelled {
                logger.error("Search failed: \(error.localizedDescription)")
                loadingState = .error(error.localizedDescription)
            }
        }
    }

    /// Clears search results.
    func clear() {
        searchTask?.cancel()
        query = ""
        results = .empty
        loadingState = .idle
    }
}
