import Foundation
import Observation

/// View model for the YouTube Explore surface (public destination feeds —
/// the successors to the retired Trending page).
@MainActor
@Observable
final class YouTubeExploreViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Videos for the selected destination.
    private(set) var videos: [YouTubeVideo] = []

    /// The selected destination category.
    var selectedDestination: YouTubeDestination = .gaming {
        didSet {
            guard oldValue != self.selectedDestination else { return }
            self.videos = []
            self.loadingState = .idle
        }
    }

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        let destination = self.selectedDestination
        do {
            let feed = try await client.getDestinationFeed(destination)
            // Ignore stale results if the user switched categories mid-flight.
            guard destination == self.selectedDestination else { return }
            self.videos = feed.videos
            self.loadingState = .loaded
        } catch {
            guard destination == self.selectedDestination else { return }
            self.logger.error("Failed to load destination feed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        self.loadingState = .idle
        self.videos = []
        await self.load()
    }
}
