import Foundation
import Observation

@MainActor
@Observable
final class YouTubeExploreViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var videos: [YouTubeVideo] = []

    var selectedDestination: YouTubeDestination = .gaming {
        didSet {
            guard oldValue != self.selectedDestination else { return }
            self.cancelLoad()
            self.videos = []
            self.loadingState = .idle
        }
    }

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    private var loadGeneration = 0

    private var loadTask: Task<Void, Never>?

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
        let destination = self.selectedDestination
        do {
            let feed = try await self.client.getDestinationFeed(destination)
            guard runID == self.loadGeneration,
                  destination == self.selectedDestination else { return }
            self.videos = feed.videos
            self.loadingState = .loaded
        } catch {
            guard runID == self.loadGeneration,
                  destination == self.selectedDestination else { return }
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load destination feed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        self.cancelLoad()
        self.loadingState = .idle
        self.videos = []
        await self.load()
    }

    func cancelLoad() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.loadGeneration += 1
    }
}
