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

    /// Loads new releases content with fast initial load.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading new releases content")

        do {
            let response = try await client.getNewReleases()
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreNewReleasesSections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            let sectionCount = self.sections.count
            self.logger.info("New releases content loaded: \(sectionCount) sections")

            // Start background loading of additional sections
            self.startBackgroundLoading()
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("New releases load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load new releases: \(error.localizedDescription)")
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
                if let additionalSections = try await client.getNewReleasesContinuation() {
                    self.sections.append(contentsOf: additionalSections)
                    self.continuationsLoaded += 1
                    self.hasMoreSections = self.client.hasMoreNewReleasesSections
                    let continuationNum = self.continuationsLoaded
                    self.logger.info("Background loaded \(additionalSections.count) more sections (continuation \(continuationNum))")
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

    /// Refreshes new releases content.
    func refresh() async {
        self.backgroundLoadTask?.cancel()
        self.sections = []
        self.hasMoreSections = true
        self.continuationsLoaded = 0
        await self.load()
    }
}
