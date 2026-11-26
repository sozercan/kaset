import Foundation
import Observation

@MainActor
@Observable
final class YouTubePlaylistViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var detail: YouTubePlaylistDetail?

    let playlistId: String
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
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }
}
