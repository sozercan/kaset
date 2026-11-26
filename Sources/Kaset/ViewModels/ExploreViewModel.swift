import Foundation
import Observation
import os

@MainActor
@Observable
final class ExploreViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var sections: [HomeSection] = []

    private(set) var hasMoreSections: Bool = true

    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api
    private var isLoadingMoreSections = false

    @ObservationIgnored private var continuationWaiters: [CheckedContinuation<Void, Never>] = []

    private var loadGeneration = 0

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        self.logger.info("Loading explore content")

        do {
            let response = try await self.client.getExplore()
            guard generation == self.loadGeneration else { return }
            self.sections = response.sections.filter { !self.isChartsSection($0) }
            self.hasMoreSections = self.hasMoreSectionsForCurrentSource
            self.loadingState = .loaded
            let sectionCount = self.sections.count
            self.logger.info("Explore content loaded: \(sectionCount) sections")
        } catch is CancellationError {
            guard generation == self.loadGeneration else { return }
            self.logger.debug("Explore load cancelled")
            self.loadingState = .idle
        } catch {
            guard generation == self.loadGeneration else { return }
            self.logger.error("Failed to load explore: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

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
            if let additionalSections = try await self.getContinuationForCurrentSource() {
                guard generation == self.loadGeneration else { return }
                let sectionsToAppend = additionalSections.filter { !self.isChartsSection($0) }
                self.sections.append(contentsOf: sectionsToAppend)
                self.hasMoreSections = self.hasMoreSectionsForCurrentSource
                self.logger.info("Loaded \(sectionsToAppend.count) more explore sections on demand")
            } else {
                guard generation == self.loadGeneration else { return }
                self.hasMoreSections = false
            }
        } catch is CancellationError {
            self.logger.debug("Explore continuation load cancelled")
        } catch {
            self.logger.warning("Explore continuation load failed: \(error.localizedDescription)")
        }
    }

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

    private var hasMoreSectionsForCurrentSource: Bool {
        self.client.hasMoreExploreSections
    }

    private func getContinuationForCurrentSource() async throws -> [HomeSection]? {
        try await self.client.getExploreContinuation()
    }

    private func isChartsSection(_ section: HomeSection) -> Bool {
        section.title.lowercased() == "charts"
    }
}
