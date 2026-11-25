import Foundation
import Observation

@MainActor
@Observable
final class YouTubePlaylistsViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var playlists: [YouTubePlaylist] = []

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
            let playlists = try await self.client.getUserPlaylists()
            guard runID == self.loadGeneration else { return }
            self.playlists = playlists
            self.loadingState = .loaded
        } catch {
            guard runID == self.loadGeneration else { return }
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube playlists: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        self.cancelLoad()
        self.loadingState = .idle
        self.playlists = []
        await self.load()
    }

    func cancelLoad() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.loadGeneration += 1
    }
}
