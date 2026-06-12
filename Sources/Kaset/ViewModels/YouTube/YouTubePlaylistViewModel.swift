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
    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(playlistId: String, client: any YouTubeClientProtocol) {
        self.playlistId = playlistId
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        do {
            self.detail = try await self.client.getPlaylist(playlistId: self.playlistId)
            self.loadingState = .loaded
        } catch {
            self.logger.error("Failed to load YouTube playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }
}
