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
    /// Task for background loading, cancelled in deinit.
    @ObservationIgnored private var backgroundLoadTask: Task<Void, Never>?
    /// Task for delayed playback-driven refreshes, cancelled in deinit/reset.
    @ObservationIgnored private var playbackRefreshTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    /// Number of background continuations loaded.
    private var continuationsLoaded = 0

    /// Maximum continuations to load in background.
    private static let maxContinuations = 4

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
        self.backgroundLoadTask?.cancel()
        self.playbackRefreshTask?.cancel()
    }

    /// Loads history content with fast initial load.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading history content")

        do {
            let response = try await self.client.getHistory()
            self.initialSections = response.sections
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHistorySections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            let sectionCount = self.sections.count
            self.logger.info("History content loaded: \(sectionCount) sections")

            self.startBackgroundLoading()
        } catch is CancellationError {
            self.logger.debug("History load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load history: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Resets local history state, used when switching accounts.
    func reset() {
        self.backgroundLoadTask?.cancel()
        self.playbackRefreshTask?.cancel()
        self.loadingState = .idle
        self.sections = []
        self.initialSections = []
        self.hasMoreSections = true
        self.continuationsLoaded = 0
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

    /// Loads more sections in the background progressively.
    private func startBackgroundLoading(skippingPreviouslyLoadedContinuations pagesToSkip: Int = 0) {
        self.backgroundLoadTask?.cancel()
        self.backgroundLoadTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            await self.loadMoreSections(skippingPreviouslyLoadedContinuations: pagesToSkip)
        }
    }

    /// Loads additional sections from continuations progressively.
    private func loadMoreSections(skippingPreviouslyLoadedContinuations pagesToSkip: Int = 0) async {
        var skippedContinuations = 0

        while self.hasMoreSections, self.continuationsLoaded < Self.maxContinuations {
            guard self.loadingState == .loaded else { break }

            do {
                if let additionalSections = try await self.client.getHistoryContinuation() {
                    self.hasMoreSections = self.client.hasMoreHistorySections

                    if skippedContinuations < pagesToSkip {
                        skippedContinuations += 1
                        let skippedCount = additionalSections.count
                        let skippedContinuation = skippedContinuations
                        self.logger.debug(
                            "Skipped \(skippedCount) already-loaded history sections from continuation \(skippedContinuation)"
                        )
                        continue
                    }

                    self.sections.append(contentsOf: additionalSections)
                    self.continuationsLoaded += 1
                    let continuationNum = self.continuationsLoaded
                    self.logger.info(
                        "Background loaded \(additionalSections.count) more history sections (continuation \(continuationNum))"
                    )
                } else {
                    self.hasMoreSections = false
                    break
                }
            } catch is CancellationError {
                self.logger.debug("Background history loading cancelled")
                break
            } catch {
                self.logger.warning("Background history section load failed: \(error.localizedDescription)")
                break
            }
        }

        let totalCount = self.sections.count
        self.logger.info("Background history section loading completed, total sections: \(totalCount)")
    }

    /// Refreshes history content while keeping existing data visible.
    /// Skips update if data hasn't changed to avoid scroll jitter.
    /// Returns true if data changed, false otherwise.
    @discardableResult
    func refresh() async -> Bool {
        self.backgroundLoadTask?.cancel()

        do {
            let response = try await self.client.getHistory()
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
                    self.logger.debug("History unchanged, skipping update")
                }

                self.startBackgroundLoading(
                    skippingPreviouslyLoadedContinuations: shouldPreservePaginatedSections ? previousContinuationsLoaded : 0
                )
                return false
            }

            self.initialSections = response.sections
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHistorySections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            self.logger.info("History refreshed: \(response.sections.count) sections")
            self.startBackgroundLoading()
            return true
        } catch is CancellationError {
            self.logger.debug("History refresh cancelled")
            return false
        } catch {
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

    /// Compares refreshed first-page sections using stable section and item identifiers.
    private func sectionsChanged(_ oldSections: [HomeSection], comparedTo newSections: [HomeSection]) -> Bool {
        guard oldSections.count == newSections.count else { return true }

        for (oldSection, newSection) in zip(oldSections, newSections) {
            if oldSection.id != newSection.id { return true }
            if oldSection.title != newSection.title { return true }
            if oldSection.isChart != newSection.isChart { return true }
            if oldSection.items.map(\.id) != newSection.items.map(\.id) { return true }
        }

        return false
    }
}
