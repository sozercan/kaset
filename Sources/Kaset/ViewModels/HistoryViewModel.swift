import Foundation
import Observation
import os

/// View model for the History view.
@MainActor
@Observable
final class HistoryViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// History sections to display (grouped by time: Today, Yesterday, etc.).
    private(set) var sections: [HomeSection] = []

    /// Whether more sections are available to load.
    private(set) var hasMoreSections: Bool = true

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.history
    // swiftformat:disable modifierOrder
    /// Explicit user-requested continuation task, cancelled in reset.
    @ObservationIgnored private var continuationTask: Task<Void, Never>?
    @ObservationIgnored private var continuationTaskID: UUID?
    /// Task for delayed playback-driven refreshes, cancelled in deinit/reset.
    @ObservationIgnored private var playbackRefreshTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    /// Number of continuation pages currently represented in `sections`.
    private var continuationsLoaded = 0

    /// Preserved continuation pages to skip after `getHistory()` rewinds the client cursor.
    private var pendingContinuationSkips = 0

    /// Whether a user-visible continuation load is currently in flight.
    private var isLoadingMoreSections = false

    /// Whether a refresh is currently rewinding the history cursor.
    private(set) var isRefreshingHistory = false

    /// Monotonic token used to discard stale continuation results after refreshes/resets.
    private var loadGeneration = 0

    /// Cached first page from the last successful history fetch.
    private var initialSections: [HomeSection] = []

    /// Last playback video ID observed while History was mounted.
    private var lastSeenPlaybackVideoId: String?

    /// Delay before refreshing after playback changes to allow history to propagate.
    static var playbackRefreshDelay: Duration = .seconds(3)

    /// Retry delay when the first playback refresh does not update the first page.
    static var playbackRefreshRetryDelay: Duration = .seconds(2)

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    deinit {
        self.continuationTask?.cancel()
        self.playbackRefreshTask?.cancel()
    }

    /// Loads history content with fast initial load.
    func load() async {
        guard self.loadingState != .loading,
              self.loadingState != .loadingMore
        else { return }

        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        self.logger.info("Loading history content")

        do {
            let response = try await self.client.getHistory()
            guard generation == self.loadGeneration else { return }
            self.initialSections = response.sections
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHistorySections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            self.pendingContinuationSkips = 0
            let sectionCount = self.sections.count
            self.logger.info("History content loaded: \(sectionCount) sections")
        } catch is CancellationError {
            guard generation == self.loadGeneration else { return }
            self.logger.debug("History load cancelled")
            self.loadingState = .idle
        } catch {
            guard generation == self.loadGeneration else { return }
            self.logger.error("Failed to load history: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Resets local history state, used when switching accounts.
    func reset() {
        self.continuationTask?.cancel()
        self.continuationTask = nil
        self.continuationTaskID = nil
        self.playbackRefreshTask?.cancel()
        self.loadGeneration += 1
        self.loadingState = .idle
        self.sections = []
        self.initialSections = []
        self.hasMoreSections = true
        self.continuationsLoaded = 0
        self.pendingContinuationSkips = 0
        self.isLoadingMoreSections = false
        self.isRefreshingHistory = false
        self.lastSeenPlaybackVideoId = nil
    }

    /// Records the currently observed playback without scheduling a refresh.
    /// Used to establish a baseline after the initial history load completes.
    func syncObservedPlayback(videoId: String?) {
        self.lastSeenPlaybackVideoId = videoId
    }

    /// Schedules a delayed refresh when playback changes to a new video.
    func schedulePlaybackRefreshIfNeeded(for videoId: String?) {
        guard let videoId else {
            self.lastSeenPlaybackVideoId = nil
            return
        }

        guard self.loadingState == .loaded else {
            self.lastSeenPlaybackVideoId = videoId
            return
        }

        guard videoId != self.lastSeenPlaybackVideoId else { return }

        self.lastSeenPlaybackVideoId = videoId
        self.playbackRefreshTask?.cancel()
        self.playbackRefreshTask = Task { [weak self] in
            await self?.refreshAfterPlaybackChange()
        }
    }

    /// Loads one additional history continuation page on explicit user demand.
    func loadMore() async {
        guard self.hasMoreSections,
              self.continuationTask == nil,
              !self.isRefreshingHistory,
              self.loadingState == .loaded
        else { return }

        let generation = self.loadGeneration
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadMore(generation: generation, taskID: taskID)
        }
        self.continuationTask = task
        self.continuationTaskID = taskID
        defer { self.clearContinuationTaskIfCurrent(taskID) }
        await task.value
    }

    private func performLoadMore(generation: Int, taskID: UUID) async {
        guard generation == self.loadGeneration, !Task.isCancelled else { return }

        self.isLoadingMoreSections = true
        self.loadingState = .loadingMore
        defer {
            if generation == self.loadGeneration {
                self.isLoadingMoreSections = false
                self.clearContinuationTaskIfCurrent(taskID)
                if self.loadingState == .loadingMore {
                    self.loadingState = .loaded
                }
            }
        }

        do {
            var skipsRemaining = self.pendingContinuationSkips
            while skipsRemaining > 0 {
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
                guard let skippedSections = try await self.client.getHistoryContinuation() else {
                    guard generation == self.loadGeneration else { return }
                    self.pendingContinuationSkips = 0
                    self.hasMoreSections = false
                    return
                }
                guard generation == self.loadGeneration else { return }
                skipsRemaining -= 1
                self.pendingContinuationSkips = skipsRemaining
                self.hasMoreSections = self.client.hasMoreHistorySections
                self.logger.debug("Skipped \(skippedSections.count) preserved history sections")
            }

            if let additionalSections = try await self.client.getHistoryContinuation() {
                guard generation == self.loadGeneration else { return }
                self.sections.append(contentsOf: additionalSections)
                self.continuationsLoaded += 1
                self.hasMoreSections = self.client.hasMoreHistorySections
                self.logger.info("Loaded \(additionalSections.count) more history sections on demand")
            } else {
                guard generation == self.loadGeneration else { return }
                self.hasMoreSections = false
            }
        } catch is CancellationError {
            self.logger.debug("History continuation load cancelled")
        } catch {
            self.logger.warning("History continuation load failed: \(error.localizedDescription)")
        }
    }

    /// Refreshes history content while keeping existing data visible.
    /// Skips update if data hasn't changed to avoid scroll jitter.
    /// Returns true if data changed, false otherwise.
    @discardableResult
    func refresh() async -> Bool {
        guard !self.isRefreshingHistory else { return false }

        self.isRefreshingHistory = true
        defer { self.isRefreshingHistory = false }

        await self.cancelInFlightContinuation()
        let generation = self.loadGeneration

        do {
            let response = try await self.client.getHistory()
            guard generation == self.loadGeneration else { return false }
            let previousContinuationsLoaded = self.continuationsLoaded
            let shouldPreservePaginatedSections =
                previousContinuationsLoaded > 0 && self.sections.count > response.sections.count

            // Compare only the refreshed first page against the last successful first page.
            // `getHistory()` rewinds the continuation cursor, so preserving already-loaded
            // continuation pages requires skipping those pages when background loading restarts.
            if !self.sectionsChanged(self.initialSections, comparedTo: response.sections) {
                self.initialSections = response.sections
                self.hasMoreSections = self.client.hasMoreHistorySections
                self.loadingState = .loaded

                if shouldPreservePaginatedSections {
                    self.logger.debug("History first page unchanged, preserving paginated sections")
                } else {
                    self.sections = response.sections
                    self.continuationsLoaded = 0
                    self.pendingContinuationSkips = 0
                    self.logger.debug("History unchanged, skipping update")
                }

                self.pendingContinuationSkips = shouldPreservePaginatedSections ? previousContinuationsLoaded : 0
                return false
            }

            self.initialSections = response.sections
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHistorySections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            self.pendingContinuationSkips = 0
            self.logger.info("History refreshed: \(response.sections.count) sections")
            return true
        } catch is CancellationError {
            self.logger.debug("History refresh cancelled")
            return false
        } catch {
            guard generation == self.loadGeneration else { return false }
            self.logger.warning("History refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Refreshes after a playback change, retrying once if the first page is unchanged.
    func refreshAfterPlaybackChange() async {
        do {
            try await Task.sleep(for: Self.playbackRefreshDelay)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }

        let changed = await self.refresh()
        guard !Task.isCancelled else { return }
        guard !changed else { return }

        do {
            try await Task.sleep(for: Self.playbackRefreshRetryDelay)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        _ = await self.refresh()
    }

    private func cancelInFlightContinuation() async {
        guard let continuationTask else { return }
        let taskID = self.continuationTaskID
        self.loadGeneration += 1
        continuationTask.cancel()
        await continuationTask.value
        if self.continuationTaskID == taskID {
            self.continuationTask = nil
            self.continuationTaskID = nil
        }
        self.isLoadingMoreSections = false
        if self.loadingState == .loadingMore {
            self.loadingState = .loaded
        }
    }

    private func clearContinuationTaskIfCurrent(_ taskID: UUID) {
        guard self.continuationTaskID == taskID else { return }
        self.continuationTask = nil
        self.continuationTaskID = nil
    }

    /// Compares refreshed first-page sections using stable section and item identifiers.
    private func sectionsChanged(_ oldSections: [HomeSection], comparedTo newSections: [HomeSection]) -> Bool {
        guard oldSections.count == newSections.count else { return true }

        for (oldSection, newSection) in zip(oldSections, newSections) {
            if oldSection.id != newSection.id {
                return true
            }
            if oldSection.title != newSection.title {
                return true
            }
            if oldSection.isChart != newSection.isChart {
                return true
            }
            if oldSection.items.map(\.id) != newSection.items.map(\.id) {
                return true
            }
        }

        return false
    }
}
