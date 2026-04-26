import Foundation
import Observation
import os

/// View model for `ArtistDiscographyView` — loads the full album list behind
/// an Albums-shelf "See all" on an artist page.
@MainActor
@Observable
final class ArtistDiscographyViewModel {
    private(set) var loadingState: LoadingState = .idle
    private(set) var albums: [Album] = []

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
        self.logger.info("Loading artist discography: \(self.destination.endpoint.browseId)")

        do {
            let result = try await client.getArtistDiscography(
                browseId: self.destination.endpoint.browseId,
                params: self.destination.endpoint.params
            )
            self.albums = result
            self.loadingState = .loaded
            self.logger.info("Loaded \(result.count) discography albums")
        } catch is CancellationError {
            self.logger.debug("Discography load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load discography: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }
}
