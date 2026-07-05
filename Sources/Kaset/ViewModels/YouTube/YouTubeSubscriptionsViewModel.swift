import Foundation
import Observation

/// View model for the YouTube subscriptions surface: the subscribed-channel
/// rail plus the subscriptions feed.
@MainActor
@Observable
final class YouTubeSubscriptionsViewModel {
    /// Current loading state (covers the feed; the rail loads alongside).
    private(set) var loadingState: LoadingState = .idle

    /// Subscribed channels for the horizontal rail.
    private(set) var channels: [YouTubeChannel] = []

    /// Subscription feed videos.
    private(set) var videos: [YouTubeVideo] = []

    /// Continuation token for the next feed page.
    private var continuation: String?

    var hasMoreVideos: Bool {
        self.continuation != nil
    }

    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    /// The single in-flight load, shared by concurrent `load()` callers so
    /// SwiftUI `.task` restarts coalesce onto one run instead of duplicating the
    /// subscriptions feed and guide requests.
    private var loadTask: Task<Void, Never>?

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    func load() async {
        if case .loaded = self.loadingState {
            return
        }
        if let existing = self.loadTask {
            await existing.value
            return
        }
        self.loadGeneration += 1
        let runID = self.loadGeneration
        let task = Task { await self.performLoad(runID: runID) }
        self.loadTask = task
        await task.value
    }

    private func performLoad(runID: Int) async {
        defer {
            if self.loadGeneration == runID {
                self.loadTask = nil
            }
        }
        guard runID == self.loadGeneration, !Task.isCancelled else { return }
        self.loadingState = .loading
        do {
            async let feedTask = self.client.getSubscriptionsFeed()
            async let channelsTask = self.client.getSubscribedChannels()

            let feed = try await feedTask
            guard runID == self.loadGeneration else { return }
            self.videos = feed.videos
            self.continuation = feed.continuation

            // Channel rail is best-effort; the feed alone is still useful.
            let channels = await (try? channelsTask) ?? []
            guard runID == self.loadGeneration else { return }
            self.channels = channels
            self.loadingState = .loaded
        } catch {
            guard runID == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load subscriptions: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        self.cancelLoad()
        self.loadingState = .idle
        self.videos = []
        self.channels = []
        self.continuation = nil
        await self.load()
    }

    func cancelLoad() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.loadGeneration += 1
    }

    func loadMore() async {
        guard self.loadingState == .loaded, let continuation = self.continuation else { return }

        self.loadingState = .loadingMore
        do {
            let feed = try await client.getPrivateFeedContinuation(continuation: continuation)
            let existing = Set(self.videos.map(\.videoId))
            self.videos.append(contentsOf: feed.videos.filter { !existing.contains($0.videoId) })
            self.continuation = feed.continuation
            self.loadingState = .loaded
        } catch {
            // A cancelled page load is not an error; allow retrying.
            if error is CancellationError {
                self.loadingState = .loaded
                return
            }
            self.logger.error("Failed to load more subscriptions: \(error.localizedDescription)")
            self.continuation = nil
            self.loadingState = .loaded
        }
    }
}
