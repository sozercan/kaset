import Foundation
import Observation
import os

/// View model for the New Releases view.
@MainActor
@Observable
final class NewReleasesViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// New releases sections to display.
    private(set) var sections: [HomeSection] = []

    /// Whether more sections are available to load.
    private(set) var hasMoreSections: Bool = true

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api
    /// Whether a user-visible continuation load is currently in flight.
    private var isLoadingMoreSections = false

    /// Waiters that should resume once the current continuation request finishes.
    @ObservationIgnored private var continuationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Monotonic token used to discard stale continuation results after refreshes.
    private var loadGeneration = 0

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Loads new releases content with fast initial load.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        self.logger.info("Loading new releases content")

        do {
            let response = try await client.getNewReleases()
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreNewReleasesSections
            self.loadingState = .loaded
            let sectionCount = self.sections.count
            self.logger.info("New releases content loaded: \(sectionCount) sections")
        } catch is CancellationError {
            guard generation == self.loadGeneration else { return }
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("New releases load cancelled")
            self.loadingState = .idle
        } catch {
            guard generation == self.loadGeneration else { return }
            self.logger.error("Failed to load new releases: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads one additional continuation page on explicit user demand.
    func loadMore() async {
        guard self.hasMoreSections,
              !self.isLoadingMoreSections,
              self.loadingState == .loaded
        else { return }

        let generation = self.loadGeneration
        self.isLoadingMoreSections = true
        self.loadingState = .loadingMore
        defer {
            self.isLoadingMoreSections = false
            if self.loadingState == .loadingMore {
                self.loadingState = .loaded
            }
            self.resumeContinuationWaiters()
        }

        do {
            if let additionalSections = try await client.getNewReleasesContinuation() {
                guard generation == self.loadGeneration else { return }
                let sectionsToAppend = additionalSections
                self.sections.append(contentsOf: sectionsToAppend)
                self.hasMoreSections = self.client.hasMoreNewReleasesSections
                self.logger.info("Loaded \(sectionsToAppend.count) more new releases sections on demand")
            } else {
                guard generation == self.loadGeneration else { return }
                self.hasMoreSections = false
            }
        } catch is CancellationError {
            self.logger.debug("New releases continuation load cancelled")
        } catch {
            self.logger.warning("New releases continuation load failed: \(error.localizedDescription)")
        }
    }

    /// Refreshes new releases content.
    func refresh() async {
        await self.waitForInFlightContinuation()
        self.sections = []
        self.hasMoreSections = true
        self.isLoadingMoreSections = false
        await self.load()
    }

    private func waitForInFlightContinuation() async {
        guard self.isLoadingMoreSections else { return }
        await withCheckedContinuation { continuation in
            self.continuationWaiters.append(continuation)
        }
    }

    private func resumeContinuationWaiters() {
        let waiters = self.continuationWaiters
        self.continuationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
