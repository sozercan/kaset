import Foundation
import Observation

/// View model for the Podcasts view.
@MainActor
@Observable
final class PodcastsViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Podcast sections to display.
    private(set) var sections: [PodcastSection] = []

    /// Whether more sections are available to load.
    private(set) var hasMoreSections: Bool = true

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    /// Service that tracks per-account region availability of the
    /// podcasts discovery surface. Configured post-init by the owning
    /// view so existing call sites/previews can construct the viewmodel
    /// without the service.
    private(set) var availabilityService: PodcastsAvailabilityService?
    /// Account id that owns the current load — passed through to
    /// `availabilityService` so 404 / empty results are recorded against
    /// the right key. Updated by `configure` on account switches.
    private(set) var accountId: String?
    private let logger = DiagnosticsLogger.api
    /// Whether a user-visible continuation load is currently in flight.
    private var isLoadingMoreSections = false

    /// Current explicit continuation request, cancelled on account switch.
    @ObservationIgnored private var continuationTask: Task<Void, Never>?
    @ObservationIgnored private var continuationTaskID: UUID?

    /// Incremented whenever foreground load results should no longer be
    /// allowed to mutate this view model (account switch, refresh, or a
    /// newer load).
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

    /// Wires the viewmodel up to the availability service and the
    /// currently-active account. Called by `MainWindow` on first display
    /// and whenever the active account changes. Safe to call repeatedly.
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

    /// Loads podcasts content with fast initial load.
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

            // Tell the availability service what we just observed. A
            // user-initiated load is authoritative, so empty payloads
            // count as "unavailable" here (unlike the background probe).
            if self.sections.isEmpty {
                self.availabilityService?.markUnavailable(for: loadAccountId)
            } else {
                self.availabilityService?.markAvailable(for: loadAccountId)
            }
        } catch is CancellationError {
            guard self.isCurrentLoad(generation: loadGeneration, accountId: loadAccountId) else { return }

            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Podcasts load cancelled")
            self.loadingState = .idle
        } catch let YTMusicError.apiError(_, code) where code == 404 {
            guard self.isCurrentLoad(generation: loadGeneration, accountId: loadAccountId) else {
                self.logger.debug("Ignoring stale podcasts 404")
                return
            }

            // Region without podcasts. Land on `.loaded` with empty
            // sections — the sidebar row will disappear within a frame
            // via the availability service, so a generic error toast
            // would be misleading.
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

    /// Loads one additional podcast continuation page on explicit user demand.
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

    /// Refreshes podcasts content.
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
