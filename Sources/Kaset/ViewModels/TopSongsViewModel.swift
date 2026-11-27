import Foundation
import Observation
import os

@MainActor
@Observable
final class TopSongsViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var songs: [Song] = []

    private let destination: TopSongsDestination
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    var title: String {
        self.destination.title
    }

    init(destination: TopSongsDestination, client: any YTMusicClientProtocol) {
        self.destination = destination
        self.client = client
        self.songs = destination.songs
    }

    func load() async {
        guard let browseId = destination.songsBrowseId else {
            self.loadingState = .loaded
            return
        }

        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading all artist songs: \(browseId)")

        do {
            let allSongs = try await client.getArtistSongs(
                browseId: browseId,
                params: self.destination.songsParams
            )

            if !allSongs.isEmpty {
                self.songs = allSongs
            }
            self.loadingState = .loaded
            let songCount = self.songs.count
            self.logger.info("Loaded \(songCount) artist songs")
        } catch is CancellationError {
            self.logger.debug("Artist songs load cancelled")
            self.loadingState = .loaded
        } catch {
            let errorMessage = error.localizedDescription
            self.logger.error("Failed to load artist songs: \(errorMessage)")
            self.loadingState = .loaded
        }
    }
}
