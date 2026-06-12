import Foundation
import Observation

/// View model for YouTube watch history.
@MainActor
@Observable
final class YouTubeHistoryViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// History videos (most recent first, as served).
    private(set) var videos: [YouTubeVideo] = []

    /// Continuation token for the next page.
    private var continuation: String?

    var hasMoreVideos: Bool {
        self.continuation != nil
    }

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        do {
            let feed = try await client.getHistory()
            self.videos = feed.videos
            self.continuation = feed.continuation
            self.loadingState = .loaded
        } catch {
            // A cancelled load (view went away mid-flight) is not an
            // error; the next .task run reloads.
            if error is CancellationError { return }
            self.logger.error("Failed to load YouTube history: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        self.loadingState = .idle
        self.videos = []
        self.continuation = nil
        await self.load()
    }

    func loadMore() async {
        guard self.loadingState == .loaded, let continuation = self.continuation else { return }

        self.loadingState = .loadingMore
        do {
            let feed = try await client.getFeedContinuation(continuation: continuation)
            let existing = Set(self.videos.map(\.videoId))
            self.videos.append(contentsOf: feed.videos.filter { !existing.contains($0.videoId) })
            self.continuation = feed.continuation
            self.loadingState = .loaded
        } catch {
            // A cancelled load (view went away mid-flight) is not an
            // error; the next .task run reloads.
            if error is CancellationError { return }
            self.logger.error("Failed to load more history: \(error.localizedDescription)")
            self.continuation = nil
            self.loadingState = .loaded
        }
    }
}
