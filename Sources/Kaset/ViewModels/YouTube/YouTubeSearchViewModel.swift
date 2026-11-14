import Foundation
import Observation

// MARK: - YouTubeSearchViewModel

/// View model for YouTube search.
@MainActor
@Observable
final class YouTubeSearchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Current search query.
    var query: String = "" {
        didSet {
            self.handleQueryChange(from: oldValue)
        }
    }

    /// Search results.
    private(set) var results: YouTubeSearchResponse = .empty

    /// Filter for result kinds.
    var selectedFilter: YouTubeSearchFilter = .all {
        didSet {
            guard oldValue != self.selectedFilter else { return }
            self.handleFilterChange()
        }
    }

    /// YouTube searches made in Kaset, most recent first.
    private(set) var recentSearches: [String]

    /// The signed-in account's YouTube search history, most recent first.
    /// Empty when signed out, on a brand account, or before it loads.
    private(set) var accountSearchHistory: [String] = []

    /// Whether the account search history is loading for the first time.
    private(set) var isLoadingAccountSearchHistory = false

    /// Bumped when removing an account search history entry fails.
    private(set) var searchHistoryFailureCount = 0

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var paginationTask: Task<Void, Never>?
    @ObservationIgnored private var accountHistoryTask: Task<Void, Never>?
    @ObservationIgnored private var accountHistoryLoadedAt: Date?
    /// Bumped by removals so loads that started earlier can't put a removed
    /// entry back when they finish.
    @ObservationIgnored private var accountHistoryGeneration = 0

    private var searchGeneration = 0
    private var activeSearchRequest: SearchRequest?
    private var activePaginationRequest: PaginationRequest?
    private var publishedSearchContext: SearchContext?
    private var publishedSearchGeneration: Int?

    let client: any YouTubeClientProtocol
    private let historyStore: YouTubeSearchHistoryStore
    private let logger = DiagnosticsLogger.api

    /// How long a loaded account history is reused before refetching.
    private static let accountHistoryLifetime: TimeInterval = 60

    init(
        client: any YouTubeClientProtocol,
        historyStore: YouTubeSearchHistoryStore = YouTubeSearchHistoryStore()
    ) {
        self.client = client
        self.historyStore = historyStore
        self.recentSearches = historyStore.entries
    }

    /// Performs a search for the current query and filter.
    func search() async {
        guard let context = self.currentSearchContext else {
            self.resetForEmptyQuery()
            return
        }

        self.historyStore.record(context.query)
        self.recentSearches = self.historyStore.entries
        // Signed-in searches land in the account history too; refetch it the
        // next time the history shows.
        self.accountHistoryLoadedAt = nil

        let start = self.startSearch(for: context, resetResults: false)
        if start.didCreate {
            await self.awaitStartedSearch(start)
        } else {
            await start.task.value
        }
    }

    func cancelSearch() {
        self.invalidateInFlightSearch()
        self.resetForEmptyQuery()
        self.accountHistoryTask?.cancel()
        self.accountHistoryTask = nil
    }

    /// Loads the next page of results.
    func loadMore() async {
        guard self.loadingState == .loaded,
              let continuation = self.results.continuation,
              let context = self.publishedSearchContext,
              let generation = self.publishedSearchGeneration,
              self.isCurrentPublishedSearch(context: context, generation: generation)
        else { return }

        let request = PaginationRequest(context: context, generation: generation, continuation: continuation)
        let start = self.startPagination(request)
        if start.didCreate {
            await self.awaitStartedPagination(start)
        } else {
            await start.task.value
        }
    }

    // MARK: - Search History

    /// Recent Kaset searches matching what is typed in the search field.
    var visibleRecentSearches: [String] {
        self.matchingQuery(self.recentSearches)
    }

    /// Account history entries matching the search field, minus any already
    /// listed under recent searches.
    var visibleAccountSearchHistory: [String] {
        let recent = self.recentSearches
        let accountOnly = self.accountSearchHistory.filter { entry in
            !recent.contains { YouTubeSearchHistoryStore.matches($0, entry) }
        }
        return self.matchingQuery(accountOnly)
    }

    /// Runs a search for a history entry.
    func search(historyEntry: String) async {
        self.query = historyEntry
        await self.search()
    }

    /// Loads the account's YouTube search history unless a recent copy is
    /// already showing. Concurrent callers share one request, which survives
    /// SwiftUI `.task` restarts.
    func loadAccountSearchHistory(force: Bool = false) async {
        while let accountHistoryTask {
            await accountHistoryTask.value
            // A forced load must reflect the state after the caller's change, so
            // it starts its own request instead of reusing one already running.
            guard force else { return }
        }
        if !force,
           let loadedAt = self.accountHistoryLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.accountHistoryLifetime
        {
            return
        }

        let task = Task {
            await self.performAccountHistoryLoad()
        }
        self.accountHistoryTask = task
        await task.value
    }

    /// Removes a query from Kaset's recent searches and, when it is also in
    /// the account history, from the account too.
    func removeSearchHistoryEntry(_ entry: String) async {
        self.historyStore.remove(entry)
        self.recentSearches = self.historyStore.entries

        guard let accountEntry = self.accountSearchHistory.first(where: {
            YouTubeSearchHistoryStore.matches($0, entry)
        }) else {
            return
        }

        let previous = self.accountSearchHistory
        self.accountHistoryGeneration += 1
        self.accountSearchHistory.removeAll { YouTubeSearchHistoryStore.matches($0, entry) }
        do {
            try await self.client.removeSearchHistoryEntry(query: accountEntry)
        } catch {
            if error is CancellationError {
                return
            }
            self.logger.error("Removing YouTube search history entry failed: \(error.localizedDescription)")
            self.accountSearchHistory = previous
            self.searchHistoryFailureCount += 1
            return
        }

        // The endpoint's reply carries nothing to check, so confirm by
        // refetching: an entry that comes back was not removed.
        await self.loadAccountSearchHistory(force: true)
        if self.accountSearchHistory.contains(where: { YouTubeSearchHistoryStore.matches($0, entry) }) {
            self.searchHistoryFailureCount += 1
        }
    }

    /// Clears Kaset's recent searches. The account history is managed on Google.
    func clearRecentSearches() {
        self.historyStore.clear()
        self.recentSearches = []
    }

    private func performAccountHistoryLoad() async {
        defer { self.accountHistoryTask = nil }
        if self.accountHistoryLoadedAt == nil, self.accountSearchHistory.isEmpty {
            self.isLoadingAccountSearchHistory = true
        }
        defer { self.isLoadingAccountSearchHistory = false }

        let generation = self.accountHistoryGeneration
        do {
            let history = try await self.client.getSearchHistory()
            // A removal since this request started makes its result stale.
            guard generation == self.accountHistoryGeneration else { return }
            self.accountSearchHistory = history
            self.accountHistoryLoadedAt = Date()
        } catch {
            if error is CancellationError {
                return
            }
            // Account history is a convenience on top of recent searches; keep
            // whatever is showing and try again next time.
            self.logger.error("Loading YouTube search history failed: \(error.localizedDescription)")
        }
    }

    private func matchingQuery(_ entries: [String]) -> [String] {
        let typed = Self.normalizedQuery(self.query)
        guard !typed.isEmpty else { return entries }
        return entries.filter { $0.localizedCaseInsensitiveContains(typed) }
    }

    private var currentSearchContext: SearchContext? {
        let query = Self.normalizedQuery(self.query)
        guard !query.isEmpty else { return nil }
        return SearchContext(query: query, filter: self.selectedFilter)
    }

    private static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleQueryChange(from oldValue: String) {
        let oldQuery = Self.normalizedQuery(oldValue)
        let newQuery = Self.normalizedQuery(self.query)
        guard oldQuery != newQuery else { return }

        self.invalidateInFlightSearch()

        if newQuery.isEmpty {
            self.resetForEmptyQuery()
        } else if self.publishedSearchContext?.query != newQuery {
            self.results = .empty
            self.loadingState = .idle
            self.publishedSearchContext = nil
            self.publishedSearchGeneration = nil
        }
    }

    private func handleFilterChange() {
        guard let context = self.currentSearchContext else {
            self.invalidateInFlightSearch()
            self.resetForEmptyQuery()
            return
        }

        _ = self.startSearch(for: context, resetResults: true)
    }

    private func startSearch(for context: SearchContext, resetResults: Bool) -> StartedSearch {
        if let searchTask, let activeSearchRequest, activeSearchRequest.context == context {
            return StartedSearch(task: searchTask, request: activeSearchRequest, didCreate: false)
        }

        self.invalidateInFlightSearch()
        if resetResults {
            self.results = .empty
            self.publishedSearchContext = nil
            self.publishedSearchGeneration = nil
        }
        self.loadingState = .loading

        let request = SearchRequest(context: context, generation: self.searchGeneration)
        self.activeSearchRequest = request
        let task = Task {
            await self.performSearch(request)
        }
        self.searchTask = task
        return StartedSearch(task: task, request: request, didCreate: true)
    }

    private func awaitStartedSearch(_ start: StartedSearch) async {
        await start.task.value
    }

    private func performSearch(_ request: SearchRequest) async {
        defer {
            if self.activeSearchRequest == request {
                self.activeSearchRequest = nil
                self.searchTask = nil
            }
        }

        do {
            let results = try await client.search(query: request.context.query, filter: request.context.filter)
            guard self.isCurrentSearch(request) else { return }
            guard !Task.isCancelled else { return }

            self.results = results
            self.publishedSearchContext = request.context
            self.publishedSearchGeneration = request.generation
            self.loadingState = .loaded
        } catch {
            // A cancelled load (view went away mid-flight or a newer search
            // superseded it) is not an error; the next search owns publishing.
            if error is CancellationError {
                return
            }
            guard self.isCurrentSearch(request) else { return }
            guard !Task.isCancelled else { return }
            self.logger.error("YouTube search failed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func startPagination(_ request: PaginationRequest) -> StartedPagination {
        if let paginationTask, self.activePaginationRequest == request {
            return StartedPagination(task: paginationTask, request: request, didCreate: false)
        }

        self.loadingState = .loadingMore
        let task = Task {
            await self.performLoadMore(request)
        }
        self.activePaginationRequest = request
        self.paginationTask = task
        return StartedPagination(task: task, request: request, didCreate: true)
    }

    private func awaitStartedPagination(_ start: StartedPagination) async {
        await start.task.value
    }

    private func performLoadMore(_ request: PaginationRequest) async {
        defer {
            if self.activePaginationRequest == request || self.activePaginationRequest == nil {
                self.activePaginationRequest = nil
                self.paginationTask = nil
            }
        }

        do {
            if let more = try await client.getSearchContinuation(continuation: request.continuation) {
                guard self.isCurrentPagination(request) else { return }
                guard !Task.isCancelled else {
                    self.loadingState = .loaded
                    return
                }

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
                guard self.isCurrentPagination(request) else { return }
                self.results.continuation = nil
            }
            guard self.isCurrentPagination(request) else { return }
            self.loadingState = .loaded
        } catch {
            guard self.isCurrentPagination(request) else { return }
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

    private func invalidateInFlightSearch() {
        self.searchGeneration += 1
        self.searchTask?.cancel()
        self.searchTask = nil
        self.activeSearchRequest = nil
        _ = self.cancelInFlightPagination()
    }

    private func cancelInFlightPagination() -> Task<Void, Never>? {
        let task = self.paginationTask
        task?.cancel()
        self.activePaginationRequest = nil
        return task
    }

    private func resetForEmptyQuery() {
        self.results = .empty
        self.loadingState = .idle
        self.publishedSearchContext = nil
        self.publishedSearchGeneration = nil
    }

    private func isCurrentSearch(_ request: SearchRequest) -> Bool {
        self.activeSearchRequest == request &&
            self.searchGeneration == request.generation &&
            self.currentSearchContext == request.context
    }

    private func isCurrentPublishedSearch(context: SearchContext, generation: Int) -> Bool {
        self.searchGeneration == generation &&
            self.publishedSearchGeneration == generation &&
            self.publishedSearchContext == context &&
            self.currentSearchContext == context
    }

    private func isCurrentPagination(_ request: PaginationRequest) -> Bool {
        self.isCurrentPublishedSearch(context: request.context, generation: request.generation)
    }
}

// MARK: - SearchContext

private struct SearchContext: Equatable {
    let query: String
    let filter: YouTubeSearchFilter
}

// MARK: - SearchRequest

private struct SearchRequest: Equatable {
    let context: SearchContext
    let generation: Int
}

// MARK: - PaginationRequest

private struct PaginationRequest: Equatable {
    let context: SearchContext
    let generation: Int
    let continuation: String
}

// MARK: - StartedSearch

private struct StartedSearch {
    let task: Task<Void, Never>
    let request: SearchRequest
    let didCreate: Bool
}

// MARK: - StartedPagination

private struct StartedPagination {
    let task: Task<Void, Never>
    let request: PaginationRequest
    let didCreate: Bool
}
