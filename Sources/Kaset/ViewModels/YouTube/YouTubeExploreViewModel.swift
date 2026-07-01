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

    /// Invalidates stale in-flight loads when a newer one starts.
    private var loadGeneration = 0

    /// The single in-flight load, shared by concurrent `load()` callers so
    /// SwiftUI `.task` restarts coalesce onto one run instead of duplicating the
    /// destination feed request.
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
            // Ignore stale results (superseded load or switched category).
            guard runID == self.loadGeneration,
                  destination == self.selectedDestination else { return }
            self.videos = feed.videos
            self.loadingState = .loaded
        } catch {
            guard runID == self.loadGeneration,
                  destination == self.selectedDestination else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
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
