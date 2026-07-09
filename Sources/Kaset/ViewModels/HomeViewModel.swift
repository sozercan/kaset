import Foundation
import Observation
import os

/// View model for the Home view.
@MainActor
@Observable
final class HomeViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Home sections to display.
    private(set) var sections: [HomeSection] = []

    /// Whether more sections are available to load.
    private(set) var hasMoreSections: Bool = true

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    /// Whether a user-visible continuation load is currently in flight.
    private var isLoadingMoreSections = false

    /// Whether the initial Home request is in flight.
    private var isLoadingHome = false

    /// Shared refresh operation so concurrent callers join the same wait-and-reload
    /// sequence even when the API response completes without suspending.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Whether the current refresh cycle has issued its Home request. A refresh
    /// arriving after this point represents newer state and needs one follow-up.
    @ObservationIgnored private var refreshRequestIssued = false

    /// Coalesces any number of refreshes that arrive during one issued request
    /// into a single follow-up cycle using the latest client/account state.
    @ObservationIgnored private var refreshNeedsFollowUp = false

    /// Waiters that should resume once the current initial Home request finishes.
    @ObservationIgnored private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waiters that should resume once the current continuation request finishes.
    @ObservationIgnored private var continuationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Monotonic token used to discard stale continuation loads after refreshes.
    private var loadGeneration = 0

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Loads home content with fast initial load.
    func load() async {
        guard !self.isLoadingHome, !self.isLoadingMoreSections else { return }
        await self.performLoad()
    }

    private func performLoad() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.isLoadingHome = true
        self.loadingState = .loading
        self.logger.info("Loading home content")
        defer {
            self.isLoadingHome = false
            self.resumeLoadWaiters()
        }

        do {
            let response = try await client.getHome()
            guard generation == self.loadGeneration else { return }
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHomeSections
            self.loadingState = .loaded
            let sectionCount = self.sections.count
            self.logger.info("Home content loaded: \(sectionCount) sections")
            let sectionSummary = self.sections
                .map { "\($0.title) (\($0.items.count))" }
                .joined(separator: ", ")
            self.logger.debug("Home sections: [\(sectionSummary)]")
        } catch is CancellationError {
            guard generation == self.loadGeneration else { return }
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Home load cancelled")
            self.loadingState = .idle
        } catch {
            guard generation == self.loadGeneration else { return }
            self.logger.error("Failed to load home: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads one additional home continuation on demand, typically from the bottom-of-scroll sentinel.
    /// Avoids the previous initial background drain of up to four pages for users who never scroll.
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
            if let additionalSections = try await client.getHomeContinuation() {
                guard generation == self.loadGeneration else { return }
                self.sections.append(contentsOf: additionalSections)
                self.hasMoreSections = self.client.hasMoreHomeSections
                self.logger.info("Loaded \(additionalSections.count) more home sections on demand")
            } else {
                guard generation == self.loadGeneration else { return }
                self.hasMoreSections = false
            }
        } catch is CancellationError {
            self.logger.debug("Home continuation load cancelled")
        } catch {
            self.logger.warning("Home continuation load failed: \(error.localizedDescription)")
        }
    }

    /// Refreshes home content.
    func refresh() async {
        if let refreshTask = self.refreshTask {
            if self.refreshRequestIssued {
                self.refreshNeedsFollowUp = true
            }
            await refreshTask.value
            return
        }

        let refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRefreshLoop()
        }
        self.refreshTask = refreshTask
        await refreshTask.value
    }

    private func runRefreshLoop() async {
        defer {
            self.refreshTask = nil
            self.refreshRequestIssued = false
            self.refreshNeedsFollowUp = false
        }

        repeat {
            self.refreshRequestIssued = false
            self.refreshNeedsFollowUp = false
            await self.performRefreshCycle()
        } while self.refreshNeedsFollowUp
    }

    private func performRefreshCycle() async {
        await self.waitForInFlightLoad()
        await self.waitForInFlightContinuation()
        self.sections = []
        self.hasMoreSections = true
        self.isLoadingMoreSections = false
        self.refreshRequestIssued = true
        await self.performLoad()
    }

    private func waitForInFlightLoad() async {
        guard self.isLoadingHome else { return }
        await withCheckedContinuation { continuation in
            self.loadWaiters.append(continuation)
        }
    }

    private func waitForInFlightContinuation() async {
        guard self.isLoadingMoreSections else { return }
        await withCheckedContinuation { continuation in
            self.continuationWaiters.append(continuation)
        }
    }

    private func resumeLoadWaiters() {
        let waiters = self.loadWaiters
        self.loadWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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
