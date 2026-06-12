import Foundation
import Observation

/// View model for the signed-in user's YouTube playlists list.
@MainActor
@Observable
final class YouTubePlaylistsViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// The user's playlists.
    private(set) var playlists: [YouTubePlaylist] = []

    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let playlists = try await self.client.getUserPlaylists()
            guard generation == self.loadGeneration else { return }
            self.playlists = playlists
            self.loadingState = .loaded
        } catch {
            guard generation == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube playlists: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        self.loadingState = .idle
        self.playlists = []
        await self.load()
    }
}
