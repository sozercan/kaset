import Foundation
import Observation

@MainActor
@Observable
final class PodcastsViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var sections: [PodcastSection] = []

    private(set) var hasMoreSections: Bool = true

    let client: any YTMusicClientProtocol
    private(set) var availabilityService: PodcastsAvailabilityService?
    private(set) var accountId: String?
    private let logger = DiagnosticsLogger.api
    private var isLoadingMoreSections = false

    @ObservationIgnored private var continuationTask: Task<Void, Never>?
    @ObservationIgnored private var continuationTaskID: UUID?

    private var loadGeneration = 0

    init(
        client: any YTMusicClientProtocol,
        availabilityService: PodcastsAvailabilityService? = nil,
        accountId: String? = nil
    ) {
        self.client = client
        self.availabilityService = availabilityService
        self.accountId = accountId
    }

    func configure(
        availabilityService: PodcastsAvailabilityService?,
        accountId: String?
    ) {
        let accountChanged = self.accountId != accountId

        self.availabilityService = availabilityService
        self.accountId = accountId

        if accountChanged {
            self.resetContentForAccountSwitch()
        }
    }

    func load() async {
        guard self.loadingState != .loading,
              self.loadingState != .loadingMore
        else { return }

        self.loadGeneration += 1
        let loadGeneration = self.loadGeneration
        let loadAccountId = self.accountId

        self.loadingState = .loading
        self.logger.info("Loading podcasts content")

        do {
            let sections = try await self.client.getPodcasts()
            guard self.isCurrentLoad(generation: loadGeneration, accountId: loadAccountId) else {
                self.logger.debug("Ignoring stale podcasts load result")
                return
            }

            self.sections = sections
            self.hasMoreSections = self.client.hasMorePodcastsSections
            self.loadingState = .loaded
            let sectionCount = self.sections.count
            self.logger.info("Podcasts content loaded: \(sectionCount) sections")

            if self.sections.isEmpty {
                self.availabilityService?.markUnavailable(for: loadAccountId)
            } else {
                self.availabilityService?.markAvailable(for: loadAccountId)
            }
        } catch is CancellationError {
            guard self.isCurrentLoad(generation: loadGeneration, accountId: loadAccountId) else { return }

            self.logger.debug("Podcasts load cancelled")
            self.loadingState = .idle
        } catch let YTMusicError.apiError(_, code) where code == 404 {
            guard self.isCurrentLoad(generation: loadGeneration, accountId: loadAccountId) else {
                self.logger.debug("Ignoring stale podcasts 404")
                return
            }

            self.logger.info("Podcasts endpoint returned 404; marking region unavailable")
            self.sections = []
            self.hasMoreSections = false
            self.loadingState = .loaded
            self.availabilityService?.markUnavailable(for: loadAccountId)
        } catch {
            guard self.isCurrentLoad(generation: loadGeneration, accountId: loadAccountId) else {
                self.logger.debug("Ignoring stale podcasts load failure")
                return
            }

            self.logger.error("Failed to load podcasts: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func loadMore() async {
        guard self.hasMoreSections,
              self.continuationTask == nil,
              self.loadingState == .loaded
        else { return }

        let generation = self.loadGeneration
        let accountId = self.accountId
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadMore(generation: generation, accountId: accountId, taskID: taskID)
        }
        self.continuationTask = task
        self.continuationTaskID = taskID
        defer { self.clearContinuationTaskIfCurrent(taskID) }
        await task.value
    }

    private func performLoadMore(generation: Int, accountId: String?, taskID: UUID) async {
        guard self.isCurrentLoad(generation: generation, accountId: accountId),
              !Task.isCancelled
        else { return }

        self.isLoadingMoreSections = true
        self.loadingState = .loadingMore
        defer {
            if self.isCurrentLoad(generation: generation, accountId: accountId) {
                self.isLoadingMoreSections = false
                self.clearContinuationTaskIfCurrent(taskID)
                if self.loadingState == .loadingMore {
                    self.loadingState = .loaded
                }
            }
        }

        do {
            if let additionalSections = try await self.client.getPodcastsContinuation() {
                guard self.isCurrentLoad(generation: generation, accountId: accountId) else { return }
                self.sections.append(contentsOf: additionalSections)
                self.hasMoreSections = self.client.hasMorePodcastsSections
                self.logger.info("Loaded \(additionalSections.count) more podcast sections on demand")
            } else {
                guard self.isCurrentLoad(generation: generation, accountId: accountId) else { return }
                self.hasMoreSections = false
            }
        } catch is CancellationError {
            self.logger.debug("Podcast continuation load cancelled")
        } catch {
            self.logger.warning("Podcast continuation load failed: \(error.localizedDescription)")
        }
    }

    func refresh() async {
        await self.cancelInFlightContinuation()
        self.loadGeneration += 1
        self.sections = []
        self.hasMoreSections = true
        self.isLoadingMoreSections = false
        self.loadingState = .idle
        await self.load()
    }

    private func resetContentForAccountSwitch() {
        self.continuationTask?.cancel()
        self.continuationTask = nil
        self.continuationTaskID = nil
        self.client.resetSessionStateForAccountSwitch()
        self.loadGeneration += 1
        self.sections = []
        self.hasMoreSections = true
        self.isLoadingMoreSections = false
        self.loadingState = .idle
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
    }

    private func clearContinuationTaskIfCurrent(_ taskID: UUID) {
        guard self.continuationTaskID == taskID else { return }
        self.continuationTask = nil
        self.continuationTaskID = nil
    }

    private func isCurrentLoad(generation: Int, accountId: String?) -> Bool {
        generation == self.loadGeneration && accountId == self.accountId
    }
}
