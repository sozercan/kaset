import Foundation
import Observation
import os

/// View model for the TopSongsView.
@MainActor
@Observable
final class TopSongsViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// All loaded songs.
    private(set) var songs: [Song] = []

    private let destination: TopSongsDestination
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(destination: TopSongsDestination, client: any YTMusicClientProtocol) {
        self.destination = destination
        self.client = client
        // Start with the songs we already have
        self.songs = destination.songs
    }

    /// Loads all songs if a browse ID is available.
    func load() async {
        // If there's no browse ID, we already have all the songs
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
            self.loadingState = .loaded // Keep showing what we have
        } catch {
            let errorMessage = error.localizedDescription
            self.logger.error("Failed to load artist songs: \(errorMessage)")
            // Keep the songs we already have and just mark as loaded
            self.loadingState = .loaded
        }
    }
}
