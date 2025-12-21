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
        songs = destination.songs
    }

    /// Loads all songs if a browse ID is available.
    func load() async {
        // If there's no browse ID, we already have all the songs
        guard let browseId = destination.songsBrowseId else {
            loadingState = .loaded
            return
        }

        guard loadingState != .loading else { return }

        loadingState = .loading
        logger.info("Loading all artist songs: \(browseId)")

        do {
            let allSongs = try await client.getArtistSongs(
                browseId: browseId,
                params: destination.songsParams
            )

            if !allSongs.isEmpty {
                songs = allSongs
            }
            loadingState = .loaded
            let songCount = songs.count
            logger.info("Loaded \(songCount) artist songs")
        } catch is CancellationError {
            logger.debug("Artist songs load cancelled")
            loadingState = .loaded // Keep showing what we have
        } catch {
            let errorMessage = error.localizedDescription
            logger.error("Failed to load artist songs: \(errorMessage)")
            // Keep the songs we already have and just mark as loaded
            loadingState = .loaded
        }
    }
}
