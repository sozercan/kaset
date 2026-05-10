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
    // swiftformat:disable modifierOrder
    /// Task for background loading, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access; Swift 6.2 warning is expected.
    @ObservationIgnored private var backgroundLoadTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    /// Number of background continuations loaded.
    private var continuationsLoaded = 0

    /// Maximum continuations to load in background.
    private static let maxContinuations = 4

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
        self.availabilityService = availabilityService
        self.accountId = accountId
    }

    deinit {
        self.backgroundLoadTask?.cancel()
    }

    /// Loads podcasts content with fast initial load.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading podcasts content")

        do {
            self.sections = try await self.client.getPodcasts()

            self.hasMoreSections = self.client.hasMorePodcastsSections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            let sectionCount = self.sections.count
            self.logger.info("Podcasts content loaded: \(sectionCount) sections")

            // Tell the availability service what we just observed. A
            // user-initiated load is authoritative, so empty payloads
            // count as "unavailable" here (unlike the background probe).
            if self.sections.isEmpty {
                self.availabilityService?.markUnavailable(for: self.accountId)
            } else {
                self.availabilityService?.markAvailable(for: self.accountId)
                // Only continue progressive loading when there's real
                // content; an empty payload means there's nothing to
                // continue and the tab is about to disappear anyway.
                self.startBackgroundLoading()
            }
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Podcasts load cancelled")
            self.loadingState = .idle
        } catch let YTMusicError.apiError(_, code) where code == 404 {
            // Region without podcasts. Land on `.loaded` with empty
            // sections — the sidebar row will disappear within a frame
            // via the availability service, so a generic error toast
            // would be misleading.
            self.logger.info("Podcasts endpoint returned 404; marking region unavailable")
            self.sections = []
            self.hasMoreSections = false
            self.loadingState = .loaded
            self.availabilityService?.markUnavailable(for: self.accountId)
        } catch {
            self.logger.error("Failed to load podcasts: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads more sections in the background progressively.
    private func startBackgroundLoading() {
        self.backgroundLoadTask?.cancel()
        self.backgroundLoadTask = Task { [weak self] in
            guard let self else { return }

            // Brief delay to let the UI settle
            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            await self.loadMoreSections()
        }
    }

    /// Loads additional sections from continuations progressively.
    private func loadMoreSections() async {
        while self.hasMoreSections, self.continuationsLoaded < Self.maxContinuations {
            guard self.loadingState == .loaded else { break }

            do {
                if let additionalSections = try await client.getPodcastsContinuation() {
                    self.sections.append(contentsOf: additionalSections)
                    self.continuationsLoaded += 1
                    self.hasMoreSections = self.client.hasMorePodcastsSections
                    let continuationNum = self.continuationsLoaded
                    self.logger.info("Background loaded \(additionalSections.count) more podcast sections (continuation \(continuationNum))")
                } else {
                    self.hasMoreSections = false
                    break
                }
            } catch is CancellationError {
                self.logger.debug("Background loading cancelled")
                break
            } catch {
                self.logger.warning("Background section load failed: \(error.localizedDescription)")
                break
            }
        }

        let totalCount = self.sections.count
        self.logger.info("Background section loading completed, total sections: \(totalCount)")
    }

    /// Refreshes podcasts content.
    func refresh() async {
        self.backgroundLoadTask?.cancel()
        self.sections = []
        self.hasMoreSections = true
        self.continuationsLoaded = 0
        await self.load()
    }
}
