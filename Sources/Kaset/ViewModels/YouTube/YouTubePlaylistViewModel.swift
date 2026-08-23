import Foundation
import Observation

/// View model for a YouTube playlist page.
@MainActor
@Observable
final class YouTubePlaylistViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Loaded playlist detail.
    private(set) var detail: YouTubePlaylistDetail?

    let playlistId: String
    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(playlistId: String, client: any YouTubeClientProtocol) {
        self.playlistId = playlistId
        self.client = client
    }

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let detail = try await self.client.getPlaylist(playlistId: self.playlistId)
            guard generation == self.loadGeneration else { return }
            self.detail = detail
            self.loadingState = .loaded
        } catch {
            guard generation == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }
}
