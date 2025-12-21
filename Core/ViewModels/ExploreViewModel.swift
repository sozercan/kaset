import Foundation
import Observation
import os

/// View model for the Explore view.
@MainActor
@Observable
final class ExploreViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Explore sections to display.
    private(set) var sections: [HomeSection] = []

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Loads explore content.
    func load() async {
        guard loadingState != .loading else { return }

        loadingState = .loading
        logger.info("Loading explore content")

        do {
            let response = try await client.getExplore()
            sections = response.sections
            loadingState = .loaded
            let sectionCount = sections.count
            logger.info("Explore content loaded: \(sectionCount) sections")
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            logger.debug("Explore load cancelled")
            loadingState = .idle
        } catch {
            logger.error("Failed to load explore: \(error.localizedDescription)")
            loadingState = .error(error.localizedDescription)
        }
    }

    /// Refreshes explore content.
    func refresh() async {
        sections = []
        await load()
    }
}
