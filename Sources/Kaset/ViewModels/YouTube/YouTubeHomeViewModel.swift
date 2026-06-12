import Foundation
import Observation

/// View model for the YouTube home (recommended) feed.
@MainActor
@Observable
final class YouTubeHomeViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Videos to display in the feed grid.
    private(set) var videos: [YouTubeVideo] = []

    /// Whether more feed pages are available.
    private(set) var hasMoreVideos = true

    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    /// Loads the home feed if not already loaded.
    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let feed = try await client.getHomeFeed()
            guard generation == self.loadGeneration else { return }
            self.videos = feed.videos
            self.hasMoreVideos = self.client.hasMoreHomeFeed
            self.loadingState = .loaded
        } catch {
            guard generation == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube home feed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Forces a fresh reload (e.g. after account switches).
    func refresh() async {
        self.loadingState = .idle
        self.videos = []
        await self.load()
    }

    /// Loads the next feed page when the user nears the end of the grid.
    func loadMore() async {
        guard self.loadingState == .loaded, self.hasMoreVideos else { return }

        self.loadingState = .loadingMore
        do {
            if let feed = try await client.getHomeFeedContinuation() {
                let existing = Set(self.videos.map(\.videoId))
                self.videos.append(contentsOf: feed.videos.filter { !existing.contains($0.videoId) })
                self.hasMoreVideos = self.client.hasMoreHomeFeed
            } else {
                self.hasMoreVideos = false
            }
            self.loadingState = .loaded
        } catch {
            // A cancelled page load is not an error; allow retrying.
            if error is CancellationError {
                self.loadingState = .loaded
                return
            }
            self.logger.error("Failed to load more YouTube home feed: \(error.localizedDescription)")
            // Keep existing content; just stop paginating on error.
            self.loadingState = .loaded
            self.hasMoreVideos = false
        }
    }
}
