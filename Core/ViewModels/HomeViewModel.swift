import Foundation
import Observation
import os

/// View model for the Home view.
@MainActor
@Observable
final class HomeViewModel {
    /// Loading states for the view.
    enum LoadingState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Home sections to display.
    private(set) var sections: [HomeSection] = []

    /// The API client (exposed for navigation to detail views).
    let client: YTMusicClient
    private let logger = DiagnosticsLogger.api

    init(client: YTMusicClient) {
        self.client = client
    }

    /// Loads home content.
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
        } catch {
            logger.error("Failed to load home: \(error.localizedDescription)")
            loadingState = .error(error.localizedDescription)
        }
    }

    /// Refreshes home content.
    func refresh() async {
        sections = []
        await load()
    }
}
