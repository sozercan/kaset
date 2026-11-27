import Foundation
import Observation

@MainActor
@Observable
final class YouTubeSubscriptionsViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var channels: [YouTubeChannel] = []

    private(set) var videos: [YouTubeVideo] = []

    private var continuation: String?

    private(set) var paginationTrigger = 0

    var hasMoreVideos: Bool {
        self.continuation != nil
    }

    private var loadGeneration = 0

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
            self.paginationTrigger += 1

            let channels = await (try? channelsTask) ?? []
            guard runID == self.loadGeneration else { return }
            self.channels = channels
            self.loadingState = .loaded
        } catch {
            guard runID == self.loadGeneration else { return }
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
        self.paginationTrigger += 1
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
            self.paginationTrigger += 1
            self.loadingState = .loaded
        } catch {
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
