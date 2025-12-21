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

    /// Task for background loading of additional sections.
    private var backgroundLoadTask: Task<Void, Never>?

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Loads home content with fast initial load.
    func load() async {
        guard loadingState != .loading else { return }

        loadingState = .loading
        logger.info("Loading home content")

        do {
            let response = try await client.getHome()
            sections = response.sections
            loadingState = .loaded
            let sectionCount = sections.count
            logger.info("Home content loaded: \(sectionCount) sections")

            // Start background loading of additional sections
            startBackgroundLoading()
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            logger.debug("Home load cancelled")
            loadingState = .idle
        } catch {
            logger.error("Failed to load home: \(error.localizedDescription)")
            loadingState = .error(error.localizedDescription)
        }
    }

    /// Loads more sections in the background.
    private func startBackgroundLoading() {
        backgroundLoadTask?.cancel()
        backgroundLoadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Wait a bit to let the UI settle
            try? await Task.sleep(for: .seconds(1))

            guard !Task.isCancelled else { return }

            await loadMoreSections()
        }
    }

    /// Loads additional sections from continuations.
    private func loadMoreSections() async {
        guard hasMoreSections, loadingState == .loaded else { return }

        // Note: This requires the client to support getHomeMore
        // For now, we mark as no more sections since the basic protocol doesn't have this method
        // The optimization is in reducing initial continuations from 10 to 3
        hasMoreSections = false
        logger.info("Background section loading completed")
    }

    /// Refreshes home content.
    func refresh() async {
        backgroundLoadTask?.cancel()
        sections = []
        hasMoreSections = true
        await load()
    }
}
