import Foundation
import Observation
import os

/// View model for `ArtistEpisodesListView` — loads the full artist-page subset
/// behind a `MUSIC_PAGE_TYPE_ARTIST` "See all" destination (Latest episodes,
/// Live performances, etc.).
///
/// The response mirrors the main artist-page shape but is filtered by the
/// shelf's `params`. Whichever bucket the filter populates is what the view
/// renders.
@MainActor
@Observable
final class ArtistEpisodesListViewModel {
    private(set) var loadingState: LoadingState = .idle
    private(set) var episodes: [ArtistEpisode] = []

    let destination: ArtistSeeAllDestination
    private let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(destination: ArtistSeeAllDestination, client: any YTMusicClientProtocol) {
        self.destination = destination
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }
        self.loadingState = .loading
        self.logger.info("Loading artist episodes list: \(self.destination.endpoint.browseId)")

        do {
            let result = try await client.getArtistEpisodesList(
                browseId: self.destination.endpoint.browseId,
                params: self.destination.endpoint.params
            )
            self.episodes = result
            self.loadingState = .loaded
            self.logger.info("Loaded \(result.count) episodes")
        } catch is CancellationError {
            self.logger.debug("Artist episodes list load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load artist episodes: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }
}
