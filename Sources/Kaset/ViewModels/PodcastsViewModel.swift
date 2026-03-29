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
    private let logger = DiagnosticsLogger.api
    // swiftformat:disable modifierOrder
    /// Task for background loading, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access; Swift 6.2 warning is expected.
    nonisolated(unsafe) private var backgroundLoadTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    /// Number of background continuations loaded.
    private var continuationsLoaded = 0

    /// Maximum continuations to load in background.
    private static let maxContinuations = 4

    init(client: any YTMusicClientProtocol) {
        self.client = client
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

            // Start background loading of additional sections
            self.startBackgroundLoading()
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Podcasts load cancelled")
            self.loadingState = .idle
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
