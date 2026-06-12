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

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        do {
            self.playlists = try await self.client.getUserPlaylists()
            self.loadingState = .loaded
        } catch {
            // A cancelled load (view went away mid-flight) is not an
            // error; the next .task run reloads.
            if error is CancellationError { return }
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
