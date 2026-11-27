import Foundation
import Observation
import os

@MainActor
@Observable
final class HistoryViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var sections: [HomeSection] = []

    private(set) var hasMoreSections: Bool = true

    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.history
    // swiftformat:disable modifierOrder
    @ObservationIgnored private var continuationTask: Task<Void, Never>?
    @ObservationIgnored private var continuationTaskID: UUID?
    @ObservationIgnored private var playbackRefreshTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    private var continuationsLoaded = 0

    private var isLoadingMoreSections = false

    private(set) var isRefreshingHistory = false

    private var loadGeneration = 0

    private var initialSections: [HomeSection] = []

    private var lastSeenPlaybackVideoId: String?

    static var playbackRefreshDelay: Duration = .seconds(3)

    static var playbackRefreshRetryDelay: Duration = .seconds(2)

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    deinit {
        self.continuationTask?.cancel()
        self.playbackRefreshTask?.cancel()
    }

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
        self.isLoadingMoreSections = false
        self.isRefreshingHistory = false
        self.lastSeenPlaybackVideoId = nil
    }

    func syncObservedPlayback(videoId: String?) {
        self.lastSeenPlaybackVideoId = videoId
    }

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

    @discardableResult
    func refresh() async -> Bool {
        guard !self.isRefreshingHistory else { return false }

        self.isRefreshingHistory = true
        defer { self.isRefreshingHistory = false }

        await self.cancelInFlightContinuation()
        let generation = self.loadGeneration

        do {
            let previousContinuationsLoaded = self.continuationsLoaded
            let hasPaginatedSections = previousContinuationsLoaded > 0 && self.sections.count > self.initialSections.count

            if hasPaginatedSections {
                let snapshot = try await self.client.getHistoryFirstPageSnapshot()
                guard generation == self.loadGeneration else { return false }

                if !self.sectionsChanged(self.initialSections, comparedTo: snapshot.sections) {
                    self.initialSections = snapshot.sections
                    self.hasMoreSections = self.client.hasMoreHistorySections
                    self.loadingState = .loaded
                    self.logger.debug("History first page unchanged, preserving paginated sections and continuation cursor")
                    return false
                }
            }

            let response = try await self.client.getHistory()
            guard generation == self.loadGeneration else { return false }

            if !self.sectionsChanged(self.initialSections, comparedTo: response.sections) {
                self.initialSections = response.sections
                self.sections = response.sections
                self.hasMoreSections = self.client.hasMoreHistorySections
                self.loadingState = .loaded
                self.continuationsLoaded = 0
                self.logger.debug("History unchanged, skipping update")
                return false
            }

            self.initialSections = response.sections
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHistorySections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
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
