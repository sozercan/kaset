import Foundation
import Observation

/// View model for YouTube search.
@MainActor
@Observable
final class YouTubeSearchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Current search query.
    var query: String = "" {
        didSet {
            self.searchTask?.cancel()
            if self.query.isEmpty {
                self.results = .empty
                self.loadingState = .idle
                self.lastSearchedQuery = nil
            } else if self.query != self.lastSearchedQuery {
                self.results = .empty
                self.loadingState = .idle
            }
        }
    }

    /// Search results.
    private(set) var results: YouTubeSearchResponse = .empty

    /// Filter for result kinds.
    var selectedFilter: YouTubeSearchFilter = .all {
        didSet {
            guard oldValue != self.selectedFilter, !self.query.isEmpty else { return }
            self.searchTask = Task {
                await self.search()
            }
        }
    }

    /// The query that produced the current results.
    private var lastSearchedQuery: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    /// Performs a search for the current query and filter.
    func search() async {
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        self.loadingState = .loading
        do {
            let results = try await client.search(query: query, filter: self.selectedFilter)
            guard !Task.isCancelled else { return }
            self.results = results
            self.lastSearchedQuery = self.query
            self.loadingState = .loaded
        } catch {
            // A cancelled load (view went away mid-flight) is not an
            // error; the next .task run reloads.
            if error is CancellationError { return }
            guard !Task.isCancelled else { return }
            self.logger.error("YouTube search failed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads the next page of results.
    func loadMore() async {
        guard self.loadingState == .loaded, self.results.continuation != nil else { return }

        self.loadingState = .loadingMore
        do {
            if let more = try await client.getSearchContinuation() {
                let existingVideos = Set(self.results.videos.map(\.videoId))
                self.results.videos.append(
                    contentsOf: more.videos.filter { !existingVideos.contains($0.videoId) }
                )
                let existingChannels = Set(self.results.channels.map(\.channelId))
                self.results.channels.append(
                    contentsOf: more.channels.filter { !existingChannels.contains($0.channelId) }
                )
                let existingPlaylists = Set(self.results.playlists.map(\.playlistId))
                self.results.playlists.append(
                    contentsOf: more.playlists.filter { !existingPlaylists.contains($0.playlistId) }
                )
                self.results.continuation = more.continuation
            } else {
                self.results.continuation = nil
            }
            self.loadingState = .loaded
        } catch {
            // A cancelled page load is not an error; allow retrying.
            if error is CancellationError {
                self.loadingState = .loaded
                return
            }
            self.logger.error("YouTube search continuation failed: \(error.localizedDescription)")
            self.loadingState = .loaded
            self.results.continuation = nil
        }
    }
}
